package dev.iyscode.movil.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.iyscode.movil.GusViewModel
import dev.iyscode.movil.UiState
import dev.iyscode.movil.assistant.AssistantViewModel
import dev.iyscode.movil.bench.BenchmarkReport
import dev.iyscode.movil.diagnostics.FlightRecorder
import dev.iyscode.movil.gus.ChatMessage
import dev.iyscode.movil.gus.DeviceBudget
import dev.iyscode.movil.gus.GusCatalog
import dev.iyscode.movil.gus.GusModel
import dev.iyscode.movil.gus.ModelState

private const val BENCHMARK_ISSUE = "https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=benchmark.yml"
private const val CRASH_ISSUE = "https://github.com/DannyBaanks/iSyCodeMovil/issues/new?template=crash-report.yml"

enum class Tab(val label: String) { CHAT("GUS"), ASSISTANT("Asistente"), MODELS("Modelos"), DIAGNOSTICS("Diagnóstico") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IsyCodeRoot(vm: GusViewModel, assistant: AssistantViewModel, requestedTab: Tab?, onTabConsumed: () -> Unit, onSignIn: (String) -> Unit, onAppearanceChanged: () -> Unit) {
    val ui by vm.ui.collectAsState()
    val states by vm.store.states.collectAsState()
    var tab by rememberSaveable { mutableStateOf(if (vm.store.installedModels().isEmpty()) Tab.ASSISTANT else Tab.CHAT) }
    LaunchedEffect(requestedTab) { requestedTab?.let { tab = it; onTabConsumed() } }
    var benchmarkFor by remember { mutableStateOf<GusModel?>(null) }
    var openReport by remember { mutableStateOf<FlightRecorder.CrashReport?>(null) }

    Scaffold(
        containerColor = Iys.bgDeep,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("ISYCODE", style = MaterialTheme.typography.titleLarge, color = Iys.accent)
                        Text(
                            when (tab) {
                                Tab.CHAT -> "GUS · en este teléfono"
                                Tab.ASSISTANT -> "Google · memoria · tu PC"
                                Tab.MODELS -> "Modelos locales"
                                Tab.DIAGNOSTICS -> "Informes de fallos"
                            },
                            style = MaterialTheme.typography.bodySmall, color = Iys.textSecondary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Iys.bgDeep, titleContentColor = Iys.textPrimary),
            )
        },
        bottomBar = {
            NavigationBar(containerColor = Iys.bgBase) {
                Tab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = {
                            Icon(
                                when (t) {
                                    Tab.CHAT -> Icons.Filled.Chat
                                    Tab.ASSISTANT -> Icons.Filled.AutoAwesome
                                    Tab.MODELS -> Icons.Filled.Memory
                                    Tab.DIAGNOSTICS -> Icons.Filled.MonitorHeart
                                }, contentDescription = null,
                            )
                        },
                        label = { Text(t.label, style = MaterialTheme.typography.labelMedium) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Iys.onAccent, indicatorColor = Iys.accent,
                            selectedTextColor = Iys.accent, unselectedIconColor = Iys.textSecondary,
                            unselectedTextColor = Iys.textSecondary,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (tab) {
                Tab.CHAT -> ChatScreen(vm, ui, states, onOpenModels = { tab = Tab.MODELS }, onOpenReports = { tab = Tab.DIAGNOSTICS })
                Tab.ASSISTANT -> AssistantRoot(assistant, onSignIn = onSignIn, onAppearanceChanged = onAppearanceChanged)
                Tab.MODELS -> ModelsScreen(vm, ui, states, onBenchmark = { benchmarkFor = it }, onOpenReports = { tab = Tab.DIAGNOSTICS })
                Tab.DIAGNOSTICS -> DiagnosticsScreen(vm, ui, onOpen = { openReport = it })
            }
        }
    }

    benchmarkFor?.let { model -> BenchmarkDialog(vm, ui, model, onDismiss = { if (!ui.benchmarkRunning) benchmarkFor = null }) }
    openReport?.let { report -> ReportDialog(vm, report, onDismiss = { openReport = null }) }
}

// ── Shared pieces ───────────────────────────────────────────────────────────

@Composable
internal fun Card(modifier: Modifier = Modifier, borderColor: Color = Iys.border, content: @Composable () -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .background(Iys.bgBase, RoundedCornerShape(16.dp))
            .border(1.dp, borderColor, RoundedCornerShape(16.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) { content() }
}

@Composable
internal fun Badge(text: String, color: Color) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        modifier = Modifier.background(color.copy(alpha = 0.15f), RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
internal fun Muted(text: String, color: Color = Iys.textSecondary) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = color)
}

private fun gb(bytes: Long) = if (bytes >= 1_000_000_000) "%.1f GB".format(bytes / 1e9) else "${bytes / 1_000_000} MB"

@Composable
private fun PreviousRunBanner(report: FlightRecorder.CrashReport, onOpen: () -> Unit, onDismiss: () -> Unit) {
    Card(borderColor = Iys.red.copy(alpha = 0.5f), modifier = Modifier.clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, null, tint = Iys.red, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text("La app se cerró inesperadamente la última vez", style = MaterialTheme.typography.labelLarge,
                color = Iys.red, modifier = Modifier.weight(1f))
            IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) { Icon(Icons.Filled.Close, null, tint = Iys.textFaint) }
        }
        Text(report.summary, style = MaterialTheme.typography.bodyMedium)
        Muted("Toca para ver dónde y por qué.")
    }
}

// ── Chat ────────────────────────────────────────────────────────────────────

@Composable
private fun ChatScreen(vm: GusViewModel, ui: UiState, states: Map<String, ModelState>, onOpenModels: () -> Unit, onOpenReports: () -> Unit) {
    val installed = GusCatalog.all.filter { states[it.id] is ModelState.Ready }
    val selected = ui.selectedModelId?.let { id -> installed.firstOrNull { it.id == id } }
    LaunchedEffect(installed.size) { if (selected == null && installed.isNotEmpty()) vm.select(installed.first()) }
    var priority by remember { mutableStateOf(vm.priorityContext) }
    var savedNotice by remember { mutableStateOf(false) }
    LaunchedEffect(ui.messages.size) { savedNotice = false }

    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = 12.dp)) {
        ui.previousRunReport?.let { PreviousRunBanner(it, onOpenReports, vm::dismissPreviousRun); Spacer(Modifier.height(8.dp)) }
        if (installed.isEmpty()) {
            Card {
                Text("Todavía no tienes modelos", style = MaterialTheme.typography.titleMedium)
                Muted("GUS corre dentro de tu teléfono con llama.cpp: sin cuenta, sin clave y en modo avión. Descarga un modelo una vez y listo.")
                Button(onClick = onOpenModels) { Text("Elegir un modelo") }
            }
            return@Column
        }
        ModelPicker(installed, selected, ui, onSelect = vm::select, onClear = vm::clearChat)
        val listState = rememberLazyListState()
        LaunchedEffect(ui.messages.size, ui.generating) { if (ui.messages.isNotEmpty()) listState.animateScrollToItem(ui.messages.size) }
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 8.dp),
        ) {
            if (ui.messages.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(top = 36.dp, bottom = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text("ISYCODE", style = MaterialTheme.typography.titleLarge, color = Iys.accent)
                        Spacer(Modifier.height(8.dp))
                        Text("GUS", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(6.dp))
                        Muted("Pregunta lo que quieras. Se procesa en este teléfono.", Iys.textSecondary)
                        Spacer(Modifier.height(8.dp))
                        Muted("Los modelos pequeños inventan fechas, nombres y cifras. Úsalos para redactar o resumir, y verifica lo importante.", Iys.orange)
                    }
                }
            }
            items(ui.messages) { message ->
                MessageBubble(message, onSave = { vm.saveToMemory(message); savedNotice = true })
            }
            item {
                if (ui.generating) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Iys.accent)
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Muted(if (ui.loadingModel) "Cargando el modelo en memoria…" else "GUS está pensando…")
                            if (!ui.loadingModel) Muted("Si el modelo es grande, puede tardar un minuto. Puedes detenerlo.")
                        }
                    }
                }
                ui.error?.let { Muted(it, Iys.red) }
                if (savedNotice) Muted("Guardado en tu memoria. GUS lo usará cuando venga al caso.", Iys.green)
            }
        }
        FilterChip(
            selected = priority,
            onClick = { priority = !priority; vm.priorityContext = priority },
            label = { Text(if (priority) "Contexto prioritario: sí" else "Contexto prioritario", style = MaterialTheme.typography.labelMedium) },
            leadingIcon = { Icon(Icons.Filled.AutoAwesome, null, modifier = Modifier.size(14.dp)) },
            colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Iys.accentSoft, selectedLabelColor = Iys.accent,
                selectedLeadingIconColor = Iys.accent, labelColor = Iys.textSecondary, iconColor = Iys.textSecondary),
        )
        Composer(ui.generating, onSend = vm::send, onStop = vm::stop)
    }
}

@Composable
private fun ModelPicker(installed: List<GusModel>, selected: GusModel?, ui: UiState, onSelect: (GusModel) -> Unit, onClear: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Box(Modifier.weight(1f)) {
            OutlinedButton(onClick = { open = true }, enabled = !ui.generating) {
                Icon(Icons.Filled.Memory, null, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text(selected?.shortName ?: "Elegir modelo", style = MaterialTheme.typography.labelLarge)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                installed.forEach { m ->
                    DropdownMenuItem(text = { Text("${m.shortName} · ${gb(m.byteCount)}") }, onClick = { open = false; onSelect(m) })
                }
            }
        }
        TextButton(onClick = onClear, enabled = ui.messages.isNotEmpty() && !ui.generating) { Text("Nuevo chat") }
    }
}

@Composable
private fun MessageBubble(m: dev.iyscode.movil.ChatUiMessage, onSave: () -> Unit) {
    val mine = m.role == ChatMessage.Role.USER
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Column(
            Modifier
                .widthIn(max = 320.dp)
                .background(if (mine) Iys.accentSoft else Iys.surface, RoundedCornerShape(18.dp))
                .border(1.dp, if (mine) Iys.accent.copy(alpha = 0.45f) else Iys.border, RoundedCornerShape(18.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Text(if (mine) "Tú" else "GUS", style = MaterialTheme.typography.labelSmall, color = if (mine) Iys.accent else Iys.violet)
            SelectionContainer { Text(m.text, style = MaterialTheme.typography.bodyLarge) }
            m.meta?.let { Muted(it, Iys.textFaint) }
            if (!mine) {
                Row(
                    Modifier.clickable(onClick = onSave).padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.BookmarkAdd, null, tint = Iys.textFaint, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Muted("Guardar en memoria", Iys.textFaint)
                }
            }
        }
    }
}

@Composable
private fun Composer(generating: Boolean, onSend: (String) -> Unit, onStop: () -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    Row(
        verticalAlignment = Alignment.Bottom,
        modifier = Modifier
            .padding(bottom = 10.dp)
            .background(Iys.surface, RoundedCornerShape(24.dp))
            .border(1.dp, Iys.border, RoundedCornerShape(24.dp))
            .padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = 2.dp),
    ) {
        OutlinedTextField(
            value = text, onValueChange = { text = it },
            modifier = Modifier.weight(1f),
            placeholder = { Text("Escribe a GUS…", style = MaterialTheme.typography.bodyMedium, color = Iys.textFaint) },
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = Iys.textPrimary),
            maxLines = 5,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Color.Transparent,
                unfocusedBorderColor = Color.Transparent,
                focusedContainerColor = Color.Transparent,
                unfocusedContainerColor = Color.Transparent,
                cursorColor = Iys.accent,
            ),
        )
        val canSend = text.isNotBlank()
        Box(
            Modifier
                .padding(bottom = 8.dp, end = 4.dp)
                .size(40.dp)
                .background(if (generating || canSend) Iys.accent else Iys.surfaceHigh, CircleShape)
                .clickable(enabled = generating || canSend) {
                    if (generating) onStop() else { onSend(text); text = "" }
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (generating) Icons.Filled.Stop else Icons.AutoMirrored.Filled.Send,
                if (generating) "Detener" else "Enviar",
                tint = if (generating || canSend) Iys.onAccent else Iys.textFaint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// ── Models ──────────────────────────────────────────────────────────────────

@Composable
private fun ModelsScreen(vm: GusViewModel, ui: UiState, states: Map<String, ModelState>, onBenchmark: (GusModel) -> Unit, onOpenReports: () -> Unit) {
    var risky by remember { mutableStateOf<GusModel?>(null) }
    var deleting by remember { mutableStateOf<GusModel?>(null) }
    val recommended = GusCatalog.all.filter { !vm.isExperimentalHere(it) }
    val experimental = GusCatalog.all.filter { vm.isExperimentalHere(it) }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        uri?.let(vm::exportModels)
    }
    val importFolderLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        uri?.let { vm.importModels(listOf(it), isTree = true) }
    }
    val importFilesLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (uris.isNotEmpty()) vm.importModels(uris, isTree = false)
    }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 8.dp),
    ) {
        ui.previousRunReport?.let { item { PreviousRunBanner(it, onOpenReports, vm::dismissPreviousRun) } }
        item {
            Muted("Elige y descarga un modelo aprobado. Cada archivo se verifica con su huella SHA-256 antes de usarse. GUS funciona sin internet y no ejecuta herramientas.")
            ui.budget?.let { b ->
                Spacer(Modifier.height(4.dp))
                Muted("Este teléfono: ${gb(b.physicalMemory)} de RAM · la app puede usar ~${gb(b.appMemoryLimit)} ahora. La recomendación se calcula con ese dato real.", Iys.accent)
            }
        }
        ui.killedBenchmark?.let { killed ->
            item {
                Card(borderColor = Iys.orange.copy(alpha = 0.5f)) {
                    Text("Benchmark interrumpido", style = MaterialTheme.typography.titleMedium, color = Iys.orange)
                    Muted(killed.error ?: "Android cerró la app durante el benchmark.")
                    Row { ShareButtons(killed.json(), BENCHMARK_ISSUE); TextButton(onClick = vm::dismissKilledBenchmark) { Text("Ocultar") } }
                }
            }
        }
        items(recommended, key = { it.id }) { m ->
            ModelCard(vm, ui, m, states[m.id] ?: ModelState.NotDownloaded,
                onDownload = { if (ui.budget?.fit(m) != DeviceBudget.Fit.COMFORTABLE) risky = m else vm.download(m) },
                onDelete = { deleting = m }, onBenchmark = { onBenchmark(m) })
        }
        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Modelos experimentales (${experimental.size})", style = MaterialTheme.typography.titleMedium)
                        Muted("Más grandes o sin medir en teléfonos. Pensados para equipos con más RAM.")
                    }
                    Switch(checked = ui.showExperimental, onCheckedChange = vm::setShowExperimental,
                        colors = SwitchDefaults.colors(checkedTrackColor = Iys.accent))
                }
                if (ui.showExperimental) {
                    Muted("Riesgo real y acotado: si no cabe, Android cierra la app (sin dañar datos ni el teléfono). También puede calentarse y usar varios GB. Si pasa, el informe de fallos dirá en qué fase y con cuánta memoria.", Iys.orange)
                }
            }
        }
        if (ui.showExperimental) {
            items(experimental, key = { "exp-" + it.id }) { m ->
                ModelCard(vm, ui, m, states[m.id] ?: ModelState.NotDownloaded,
                    onDownload = { risky = m }, onDelete = { deleting = m }, onBenchmark = { onBenchmark(m) })
            }
        }
        item {
            Card {
                Text("💾 No vuelvas a descargar", style = MaterialTheme.typography.titleMedium)
                Muted("Android borra los datos de la app al desinstalarla. Guarda una copia de tus modelos en una carpeta de tu teléfono y, tras reinstalar, impórtala: se verifica la huella y no se descarga nada.")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { exportLauncher.launch(null) }, enabled = !ui.busyBackup && vm.store.installedModels().isNotEmpty()) { Text("Guardar copia") }
                    OutlinedButton(onClick = { importFolderLauncher.launch(null) }, enabled = !ui.busyBackup) { Text("Importar carpeta") }
                }
                TextButton(onClick = { importFilesLauncher.launch(arrayOf("*/*")) }, enabled = !ui.busyBackup) { Text("Importar archivos .gguf") }
                if (ui.busyBackup) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Iys.accent)
                ui.backupMessage?.let { Muted(it, Iys.accent) }
            }
        }
    }

    risky?.let { m ->
        val b = ui.budget
        AlertDialog(
            onDismissRequest = { risky = null },
            title = { Text("Modelo experimental", style = MaterialTheme.typography.titleMedium) },
            text = {
                Text(
                    "${m.shortName} necesita ~${gb(m.estimatedPeakBytes(2048))} de memoria con contexto 2K; ahora la app puede usar ~${gb(b?.appMemoryLimit ?: 0)}. " +
                        "Descarga ${gb(m.byteCount)}. Lo peor que puede pasar: Android cierra la app al cargar o generar, el teléfono se calienta o se llena el almacenamiento. " +
                        "No hay riesgo para tus datos. Si se cierra, verás el informe al volver a abrir.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            },
            confirmButton = { TextButton(onClick = { vm.download(m); risky = null }) { Text("Descargar de todos modos") } },
            dismissButton = { TextButton(onClick = { risky = null }) { Text("Cancelar") } },
        )
    }
    deleting?.let { m ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Eliminar modelo", style = MaterialTheme.typography.titleMedium) },
            text = { Text("Se eliminará ${m.shortName} de este teléfono. Los demás modelos se conservan.", style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = { vm.delete(m); deleting = null }) { Text("Eliminar", color = Iys.red) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancelar") } },
        )
    }
}

@Composable
private fun ModelCard(vm: GusViewModel, ui: UiState, m: GusModel, state: ModelState, onDownload: () -> Unit, onDelete: () -> Unit, onBenchmark: () -> Unit) {
    val uri = LocalUriHandler.current
    val selected = ui.selectedModelId == m.id
    Card(borderColor = if (selected) Iys.accent else Iys.border) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(m.shortName, style = MaterialTheme.typography.titleMedium)
                Muted("${m.vendor} · ${m.parameterLabel} · ${gb(m.byteCount)}")
            }
            if (selected) Icon(Icons.Filled.CheckCircle, "Activo", tint = Iys.accent, modifier = Modifier.size(18.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            when (ui.budget?.fit(m)) {
                DeviceBudget.Fit.COMFORTABLE -> Badge("Cabe bien", Iys.green)
                DeviceBudget.Fit.TIGHT -> Badge("Justo", Iys.yellow)
                DeviceBudget.Fit.UNLIKELY -> Badge("Probablemente no cabe", Iys.red)
                null -> {}
            }
            when (m.evidence) {
                GusModel.Evidence.DEVICE_MEASURED -> Badge("Medido en teléfono", Iys.green)
                GusModel.Evidence.DESKTOP_SMOKE -> Badge("Probado en escritorio", Iys.blue)
                GusModel.Evidence.UNMEASURED -> Badge("Sin medir", Iys.textFaint)
            }
            if (m.isExperimental) Badge("Experimental", Iys.orange)
            if (!m.commercialUse) Badge("No comercial", Iys.purple)
        }
        Muted(m.licenseName, Iys.textFaint)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Fuente", style = MaterialTheme.typography.labelMedium, color = Iys.accent,
                modifier = Modifier.clickable { uri.openUri("https://huggingface.co/${m.repository}/tree/${m.revision}") })
            Text("Licencia", style = MaterialTheme.typography.labelMedium, color = Iys.accent,
                modifier = Modifier.clickable { uri.openUri(m.licenseUrl) })
        }
        when (state) {
            ModelState.NotDownloaded -> Button(onClick = onDownload, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Download, null, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
                Text("Descargar · ${gb(m.byteCount)}")
            }
            is ModelState.Downloading -> Column {
                LinearProgressIndicator(progress = { state.progress.toFloat() }, modifier = Modifier.fillMaxWidth(), color = Iys.accent)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Muted("Descargando · ${(state.progress * 100).toInt()} % · mantén la app abierta", Iys.textSecondary)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { vm.cancelDownload(m) }) { Text("Cancelar") }
                }
            }
            ModelState.Verifying -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Iys.accent)
                Spacer(Modifier.width(8.dp)); Muted("Verificando tamaño y SHA-256…")
            }
            is ModelState.Ready -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { vm.select(m) }, enabled = !selected) { Text(if (selected) "Seleccionado" else "Usar este modelo") }
                    OutlinedButton(onClick = onDelete, colors = ButtonDefaults.outlinedButtonColors(contentColor = Iys.red)) { Text("Eliminar") }
                }
                TextButton(onClick = onBenchmark) {
                    Icon(Icons.Filled.Speed, null, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
                    Text("Benchmark en este teléfono")
                }
            }
            is ModelState.Failed -> Column {
                Muted(state.message, Iys.red)
                OutlinedButton(onClick = onDownload) { Text("Reintentar") }
            }
        }
    }
}

// ── Benchmark ───────────────────────────────────────────────────────────────

@Composable
private fun BenchmarkDialog(vm: GusViewModel, ui: UiState, model: GusModel, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Benchmark · ${model.shortName}", style = MaterialTheme.typography.titleMedium) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Muted("Protocolo v1: 4 tareas fijas, decodificación greedy, contexto 2K. Mide carga, prefill, generación, memoria pico y temperatura. El informe no contiene texto de prompts ni respuestas.")
                Muted("Si Android cierra la app, al volver podrás exportar el resultado como KILLED: también es un dato útil.", Iys.textFaint)
                if (ui.benchmarkRunning) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Iys.accent)
                        Spacer(Modifier.width(8.dp)); Text(ui.benchmarkStep, style = MaterialTheme.typography.bodyMedium)
                    }
                }
                ui.benchmarkReport?.takeIf { it.model.id == model.id }?.let { BenchmarkResult(it) }
            }
        },
        confirmButton = {
            if (!ui.benchmarkRunning) TextButton(onClick = { vm.runBenchmark(model) }) { Text(if (ui.benchmarkReport == null) "Iniciar" else "Repetir") }
        },
        dismissButton = { if (!ui.benchmarkRunning) TextButton(onClick = onDismiss) { Text("Cerrar") } },
    )
}

@Composable
private fun BenchmarkResult(r: BenchmarkReport) {
    HorizontalDivider(color = Iys.border)
    Text("Resultado · ${r.status.name}", style = MaterialTheme.typography.labelLarge, color = if (r.status == BenchmarkReport.Status.COMPLETED) Iys.green else Iys.orange)
    Muted("Carga: ${r.loadMs?.let { "%.0f ms".format(it) } ?: "—"} · memoria pico ${gb(r.peakFootprintBytes)} · temperatura ${r.thermalStart} → ${r.thermalEnd ?: "?"}")
    r.tasks.forEach { t ->
        Text("${if (t.passed) "✓" else "✗"} ${t.id}", style = MaterialTheme.typography.labelMedium)
        Muted("prefill %.1f tok/s · gen %.1f tok/s · %d→%d tok · %s".format(t.prefillTokS, t.genTokS, t.promptTokens, t.generatedTokens, t.template))
    }
    r.error?.let { Muted(it, Iys.red) }
    ShareButtons(r.json(), BENCHMARK_ISSUE)
}

@Composable
private fun ShareButtons(json: String, issueUrl: String) {
    val context = LocalContext.current
    val uri = LocalUriHandler.current
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton(onClick = { share(context, json) }) { Text("Compartir JSON") }
        TextButton(onClick = { copy(context, json) }) { Text("Copiar") }
        TextButton(onClick = { uri.openUri(issueUrl) }) { Text("GitHub") }
    }
}

private fun share(context: Context, text: String) {
    val intent = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_TEXT, text)
    context.startActivity(Intent.createChooser(intent, "Compartir informe"))
}

internal fun copy(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("iSyCode", text))
}

// ── Diagnostics ─────────────────────────────────────────────────────────────

@Composable
private fun DiagnosticsScreen(vm: GusViewModel, ui: UiState, onOpen: (FlightRecorder.CrashReport) -> Unit) {
    var confirmClear by remember { mutableStateOf(false) }
    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 8.dp),
    ) {
        item {
            Muted("Antes de cada paso riesgoso la app anota qué estaba haciendo (fase, modelo, memoria, tokens). Nunca guarda el texto de tus mensajes ni de las respuestas. Android confirma el motivo de cada cierre cuando lo registra.")
        }
        if (ui.reports.isEmpty()) {
            item { Card { Text("Sin fallos registrados ✨", style = MaterialTheme.typography.titleMedium) } }
        } else {
            item {
                TextButton(onClick = { confirmClear = true }) {
                    Icon(Icons.Filled.DeleteSweep, null, tint = Iys.red); Spacer(Modifier.width(6.dp)); Text("Borrar todos", color = Iys.red)
                }
            }
        }
        items(ui.reports, key = { it.id }) { r ->
            Card(modifier = Modifier.clickable { onOpen(r) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Warning, null, tint = Iys.red, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(r.summary, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                }
                Muted(r.createdAt, Iys.textFaint)
                Muted(r.likelyCause.take(160))
            }
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("¿Borrar todos los informes?") },
            confirmButton = { TextButton(onClick = { vm.deleteReports(); confirmClear = false }) { Text("Borrar", color = Iys.red) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancelar") } },
        )
    }
}

@Composable
private fun ReportDialog(vm: GusViewModel, report: FlightRecorder.CrashReport, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Informe", style = MaterialTheme.typography.titleMedium) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(report.summary, style = MaterialTheme.typography.labelLarge)
                Text(report.likelyCause, style = MaterialTheme.typography.bodyMedium)
                report.marker?.let { m ->
                    HorizontalDivider(color = Iys.border)
                    Muted("Fase: ${m.phase} · modelo: ${m.modelId ?: "—"} · primer plano: ${if (m.inForeground) "sí" else "no"}")
                    Muted("Pico de memoria: ${FlightRecorder.formatBytes(m.peakFootprintBytes)} · RAM: ${FlightRecorder.formatBytes(m.physicalMemory)}")
                    Muted("${m.deviceModel} · ${m.osVersion} · app ${m.appVersion}")
                }
                if (report.breadcrumbs.isNotEmpty()) {
                    HorizontalDivider(color = Iys.border)
                    Text("Últimos pasos", style = MaterialTheme.typography.labelMedium)
                    report.breadcrumbs.takeLast(12).forEach { c ->
                        Muted("${c.time.takeLast(9)} ${c.event} · uso ${FlightRecorder.formatBytes(c.footprintBytes)} · libre ${FlightRecorder.formatBytes(c.availableBytes)}")
                    }
                }
                report.systemDiagnostic?.let {
                    HorizontalDivider(color = Iys.border)
                    Text("Diagnóstico de Android", style = MaterialTheme.typography.labelMedium)
                    SelectionContainer { Muted(it.take(2000), Iys.textFaint) }
                }
                ShareButtons(vm.exportReport(report), CRASH_ISSUE)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cerrar") } },
    )
}
