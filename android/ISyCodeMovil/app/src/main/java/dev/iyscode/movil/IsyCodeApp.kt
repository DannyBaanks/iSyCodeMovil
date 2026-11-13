package dev.iyscode.movil

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import dev.iyscode.movil.assistant.GoogleAccount
import dev.iyscode.movil.assistant.MemoryStore
import dev.iyscode.movil.assistant.Notifier
import dev.iyscode.movil.diagnostics.FlightRecorder
import dev.iyscode.movil.gus.LlamaEngine
import dev.iyscode.movil.gus.ModelStore
import dev.iyscode.movil.gus.NativeLlama
import java.io.File
import java.util.UUID

class IsyCodeApp : Application() {
    lateinit var platform: AndroidPlatform
        private set
    lateinit var recorder: FlightRecorder
        private set
    lateinit var store: ModelStore
        private set
    lateinit var engine: LlamaEngine
        private set
    /** Semantic memory shared by GUS and the assistant screens. */
    lateinit var memory: MemoryStore
        private set
    lateinit var notifier: Notifier
        private set
    /** Google account shared by the Asistente and GUS. */
    lateinit var google: GoogleAccount
        private set

    override fun onCreate() {
        super.onCreate()
        platform = AndroidPlatform(this)
        // First: diagnose how the previous run ended, before any model work.
        recorder = FlightRecorder(File(filesDir, "diagnostics")) { platform.memorySample() }
        recorder.start(platform.appVersion, platform.osVersion, platform.deviceModel, platform.ramBytes)
        platform.collectSystemExits(recorder)
        if (NativeLlama.ensureLoaded()) {
            NativeLlama.nativeInstallSignalTrap(recorder.signalFile.absolutePath)
        }
        installUncaughtHandler()
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = recorder.markForeground()
            override fun onStop(owner: LifecycleOwner) = recorder.markBackground()
        })
        store = ModelStore(File(filesDir, "gus/models"))
        engine = LlamaEngine(recorder)
        memory = MemoryStore(File(filesDir, "assistant/memory.json"))
        notifier = Notifier(this)
        google = GoogleAccount(this)
    }

    private fun installUncaughtHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                recorder.save(FlightRecorder.CrashReport(
                    id = UUID.randomUUID().toString(),
                    kind = FlightRecorder.CrashReport.Kind.UNCAUGHT_EXCEPTION,
                    createdAt = FlightRecorder.now(),
                    summary = "Excepción no controlada: ${error.javaClass.simpleName}",
                    likelyCause = error.message ?: "Error de la app en Kotlin.",
                    breadcrumbs = recorder.recentBreadcrumbs(),
                    systemDiagnostic = error.stackTraceToString().take(16 * 1024),
                ))
                // The phase marker stays open, but this crash is already reported.
                recorder.endPhase("crash")
            }
            previous?.uncaughtException(thread, error)
        }
    }
}
