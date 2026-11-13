package dev.iyscode.movil

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import dev.iyscode.movil.assistant.AssistantViewModel
import dev.iyscode.movil.assistant.GoogleOAuth
import dev.iyscode.movil.assistant.Notifier
import dev.iyscode.movil.gus.ModelState
import dev.iyscode.movil.ui.IsyCodeRoot
import dev.iyscode.movil.ui.IysTheme
import dev.iyscode.movil.ui.Tab
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val viewModel: GusViewModel by viewModels()
    private val assistant: AssistantViewModel by viewModels()
    private var requestedTab by mutableStateOf<Tab?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Read before composing so the first frame already uses the chosen palette.
        val appearance = AssistantViewModel.storedAppearance(this)
        setContent {
            IysTheme(appearance) {
                IsyCodeRoot(
                    vm = viewModel,
                    assistant = assistant,
                    requestedTab = requestedTab,
                    onTabConsumed = { requestedTab = null },
                    onSignIn = { url -> startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) },
                    onAppearanceChanged = { recreate() },
                )
            }
        }
        handle(intent)
        // Keep the screen on while a model downloads: the transfer lives in
        // the app process and would pause if the phone went to sleep.
        lifecycleScope.launch {
            viewModel.store.states.collect { states ->
                if (states.values.any { it is ModelState.Downloading }) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Google's sign-in redirect and taps on assistant notifications both land here. */
    private fun handle(intent: Intent?) {
        val data = intent?.data
        if (data != null && data.toString().startsWith(GoogleOAuth.ANDROID_REDIRECT)) {
            requestedTab = Tab.ASSISTANT
            assistant.completeSignIn(data)
            setIntent(Intent(this, MainActivity::class.java))
        } else if (intent?.getBooleanExtra(Notifier.EXTRA_OPEN_ASSISTANT, false) == true) {
            requestedTab = Tab.ASSISTANT
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshBudget()
        viewModel.reloadReports()
    }
}
