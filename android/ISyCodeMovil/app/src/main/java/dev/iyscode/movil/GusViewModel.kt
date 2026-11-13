package dev.iyscode.movil

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.iyscode.movil.assistant.AssistantViewModel
import dev.iyscode.movil.assistant.ContextPriority
import dev.iyscode.movil.assistant.SemanticContext
import dev.iyscode.movil.bench.Benchmark
import dev.iyscode.movil.bench.BenchmarkReport
import dev.iyscode.movil.diagnostics.FlightRecorder
import dev.iyscode.movil.gus.ChatMessage
import dev.iyscode.movil.gus.DeviceBudget
import dev.iyscode.movil.gus.GusBuild
import dev.iyscode.movil.gus.GusCatalog
import dev.iyscode.movil.gus.GusModel
import dev.iyscode.movil.gus.LlamaEngine
import dev.iyscode.movil.gus.ModelStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

data class ChatUiMessage(val role: ChatMessage.Role, val text: String, val meta: String? = null)

data class UiState(
    val selectedModelId: String? = null,
    val messages: List<ChatUiMessage> = emptyList(),
    val generating: Boolean = false,
    val loadingModel: Boolean = false,
    val budget: DeviceBudget? = null,
    val showExperimental: Boolean = false,
    val benchmarkRunning: Boolean = false,
    val benchmarkStep: String = "",
    val benchmarkReport: BenchmarkReport? = null,
    val killedBenchmark: BenchmarkReport? = null,
    val backupMessage: String? = null,
    val busyBackup: Boolean = false,
    val reports: List<FlightRecorder.CrashReport> = emptyList(),
    val previousRunReport: FlightRecorder.CrashReport? = null,
    val error: String? = null,
)

class GusViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as IsyCodeApp
    val store: ModelStore = app.store
    private val engine: LlamaEngine = app.engine
    private val recorder = app.recorder
    private val platform = app.platform
    private val prefs = application.getSharedPreferences("gus", Context.MODE_PRIVATE)
    private val downloads = mutableMapOf<String, Job>()
    private var generationJob: Job? = null
    private val pendingBenchmark = File(application.filesDir, "benchmarks/pending.json")
    private val assistantPrefs = application.getSharedPreferences("assistant", Context.MODE_PRIVATE)
    val memory = app.memory

    private val _ui = MutableStateFlow(UiState(
        selectedModelId = prefs.getString("selected", null),
        showExperimental = prefs.getBoolean("experimental", false),
        previousRunReport = recorder.previousRunReports.firstOrNull(),
    ))
    val ui: StateFlow<UiState> = _ui.asStateFlow()

    init {
        refreshBudget()
        reloadReports()
        viewModelScope.launch {
            store.refresh()
            Benchmark.takeKilledRun(pendingBenchmark)?.let { killed -> _ui.update { it.copy(killedBenchmark = killed) } }
        }
    }

    fun refreshBudget() = _ui.update { it.copy(budget = platform.budget()) }
    fun reloadReports() = _ui.update { it.copy(reports = recorder.reports()) }

    fun setShowExperimental(value: Boolean) {
        prefs.edit().putBoolean("experimental", value).apply()
        _ui.update { it.copy(showExperimental = value) }
    }

    fun isExperimentalHere(model: GusModel): Boolean =
        model.isExperimental || ui.value.budget?.fit(model) == DeviceBudget.Fit.UNLIKELY

    // Models

    fun download(model: GusModel) {
        if (downloads[model.id]?.isActive == true) return
        downloads[model.id] = viewModelScope.launch {
            runCatching { store.download(model) }
            refreshBudget()
        }
    }

    fun cancelDownload(model: GusModel) { downloads.remove(model.id)?.cancel() }

    fun delete(model: GusModel) {
        viewModelScope.launch {
            if (engine.loadedModelId == model.id) engine.unload()
            store.delete(model)
            if (ui.value.selectedModelId == model.id) select(null)
        }
    }

    fun select(model: GusModel?) {
        prefs.edit().putString("selected", model?.id).apply()
        _ui.update { it.copy(selectedModelId = model?.id, messages = emptyList(), error = null) }
    }

    val selectedModel: GusModel? get() = ui.value.selectedModelId?.let { GusCatalog.model(it) }

    // Chat

    fun send(text: String) {
        val model = selectedModel ?: return
        val file = store.installedFile(model.id) ?: return
        if (text.isBlank() || ui.value.generating) return
        val history = ui.value.messages + ChatUiMessage(ChatMessage.Role.USER, text.trim())
        val priority = priorityContext
        if (priority) {
            // "Contexto prioritario": the user marked this message as important, so it joins the memory.
            memory.save(text.trim().take(80), text.trim(), SemanticContext.inferPath(text), ContextPriority.CRITICAL, "gus.prioritario")
        }
        _ui.update { it.copy(messages = history, generating = true, error = null) }
        generationJob = viewModelScope.launch {
            try {
                if (engine.loadedModelId != model.id) {
                    _ui.update { it.copy(loadingModel = true) }
                    engine.load(model, file)
                    _ui.update { it.copy(loadingModel = false) }
                }
                val generation = engine.generate(promptFor(model, history, priority), maxTokens = 256, temperature = 0.6f)
                val meta = "%.1f tok/s · %d tokens".format(generation.stats.generationTokensPerSecond, generation.stats.generatedTokens)
                _ui.update { it.copy(messages = it.messages + ChatUiMessage(ChatMessage.Role.ASSISTANT, generation.text.ifBlank { "…" }, meta)) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _ui.update { it.copy(error = e.message ?: "La generación falló.") }
            } finally {
                _ui.update { it.copy(generating = false, loadingModel = false) }
                refreshBudget()
            }
        }
    }

    fun stop() {
        engine.cancel()
        generationJob?.cancel()
    }

    fun clearChat() = _ui.update { it.copy(messages = emptyList(), error = null) }

    var priorityContext: Boolean
        get() = assistantPrefs.getBoolean(AssistantViewModel.PRIORITY_KEY, false)
        set(value) { assistantPrefs.edit().putBoolean(AssistantViewModel.PRIORITY_KEY, value).apply() }

    /** Saves an exchange the user chose to keep (as.save.context from the chat). */
    fun saveToMemory(message: ChatUiMessage) {
        val index = ui.value.messages.indexOf(message)
        val question = ui.value.messages.take(maxOf(index, 0)).lastOrNull { it.role == ChatMessage.Role.USER }?.text
        val summary = if (question != null && message.role == ChatMessage.Role.ASSISTANT) "Pregunta: $question\nRespuesta: ${message.text}" else message.text
        memory.save((question ?: message.text).take(80), summary, SemanticContext.inferPath(summary), ContextPriority.HIGH, "gus.chat")
    }

    /**
     * Keeps the conversation within the 2K context: a system message (with the
     * few memory notes that apply, walked branch by branch) plus the most recent turns.
     */
    private fun promptFor(model: GusModel, history: List<ChatUiMessage>, priority: Boolean = false): List<ChatMessage> {
        val lastUser = history.lastOrNull { it.role == ChatMessage.Role.USER }?.text.orEmpty()
        val memoryNote = SemanticContext.promptContext(memory.nodes.value, lastUser, priority, maxChars = if (priority) 700 else 450)
        val systemText = if (memoryNote == null) SYSTEM_PROMPT else SYSTEM_PROMPT + "\n\n" + memoryNote
        val system = ChatMessage(ChatMessage.Role.SYSTEM, model.chatSystemPrompt(systemText))
        val kept = ArrayDeque<ChatMessage>()
        var budget = 3500 - (memoryNote?.length ?: 0)
        for (m in history.asReversed()) {
            budget -= m.text.length
            if (budget < 0 && kept.isNotEmpty()) break
            kept.addFirst(ChatMessage(m.role, m.text))
        }
        return listOf(system) + kept
    }

    // Benchmark

    fun runBenchmark(model: GusModel) {
        val file = store.installedFile(model.id) ?: return
        if (ui.value.benchmarkRunning || ui.value.generating) return
        _ui.update { it.copy(benchmarkRunning = true, benchmarkReport = null, benchmarkStep = "Preparando…") }
        viewModelScope.launch {
            recorder.beginPhase("benchmark", model.id)
            val report = runCatching {
                engine.unload()
                Benchmark.run(model, file, engine, platform, GusBuild.LLAMA_CPP_COMMIT, pendingBenchmark) { step ->
                    _ui.update { it.copy(benchmarkStep = step) }
                }
            }.getOrNull()
            recorder.endPhase("benchmark", mapOf("status" to (report?.status?.name ?: "error")))
            report?.let { saveBenchmark(it) }
            _ui.update { it.copy(benchmarkRunning = false, benchmarkReport = report, benchmarkStep = "") }
            refreshBudget()
        }
    }

    fun dismissKilledBenchmark() = _ui.update { it.copy(killedBenchmark = null) }

    private fun saveBenchmark(report: BenchmarkReport) {
        runCatching {
            val dir = File(getApplication<Application>().filesDir, "benchmarks").apply { mkdirs() }
            File(dir, "${report.runId}.json").writeText(report.json())
        }
    }

    // Crash reports

    fun deleteReports() {
        recorder.deleteAllReports()
        _ui.update { it.copy(reports = emptyList(), previousRunReport = null) }
    }

    fun exportReport(report: FlightRecorder.CrashReport) = recorder.exportJson(report)

    fun dismissPreviousRun() = _ui.update { it.copy(previousRunReport = null) }

    // Backup to / import from the system file picker

    fun exportModels(treeUri: Uri) {
        val context = getApplication<Application>()
        _ui.update { it.copy(busyBackup = true, backupMessage = null) }
        viewModelScope.launch {
            val saved = withContext(Dispatchers.IO) {
                val tree = DocumentFile.fromTreeUri(context, treeUri) ?: return@withContext 0
                store.installedModels().count { model ->
                    val source = store.installedFile(model.id) ?: return@count false
                    runCatching {
                        tree.findFile(model.filename)?.delete()
                        val target = tree.createFile("application/octet-stream", model.filename) ?: error("no file")
                        context.contentResolver.openOutputStream(target.uri)!!.use { out -> source.inputStream().use { it.copyTo(out, 1 shl 20) } }
                    }.isSuccess
                }
            }
            _ui.update { it.copy(busyBackup = false, backupMessage = "Copia guardada: $saved modelo(s). Impórtala tras reinstalar.") }
        }
    }

    fun importModels(uris: List<Uri>, isTree: Boolean) {
        val context = getApplication<Application>()
        _ui.update { it.copy(busyBackup = true, backupMessage = null) }
        viewModelScope.launch {
            val candidates = withContext(Dispatchers.IO) {
                val docs = if (isTree) {
                    uris.flatMap { uri -> DocumentFile.fromTreeUri(context, uri)?.listFiles()?.toList() ?: emptyList() }
                } else {
                    uris.mapNotNull { DocumentFile.fromSingleUri(context, it) }
                }
                docs.filter { it.isFile }.map { doc ->
                    ModelStore.ImportCandidate(doc.name ?: "archivo", doc.length()) {
                        context.contentResolver.openInputStream(doc.uri) ?: error("No pude abrir ${doc.name}")
                    }
                }
            }
            val summary = store.import(candidates)
            val parts = buildList {
                if (summary.imported.isNotEmpty()) add("Importados y verificados: ${summary.imported.size}")
                if (summary.alreadyInstalled.isNotEmpty()) add("ya instalados: ${summary.alreadyInstalled.size}")
                if (summary.rejected.isNotEmpty()) add("no coinciden con el catálogo: ${summary.rejected.joinToString()}")
            }
            _ui.update { it.copy(busyBackup = false, backupMessage = parts.joinToString(" · ").ifEmpty { "No encontré archivos .gguf." }) }
            refreshBudget()
        }
    }

    companion object {
        const val SYSTEM_PROMPT =
            "Eres GUS, el asistente local de iSyCode Móvil. Respondes en el idioma del usuario, de forma breve y clara. " +
                "Funcionas sin internet y no puedes ejecutar herramientas ni cambiar archivos; si te lo piden, explica el límite y sugiere pasos. " +
                "Si no estás seguro de un dato (fechas, nombres, cifras), dilo en lugar de inventarlo."
    }
}
