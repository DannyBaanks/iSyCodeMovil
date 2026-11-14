package dev.iyscode.movil.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.iyscode.movil.assistant.Appearance
import dev.iyscode.movil.assistant.AssistantCatalog
import dev.iyscode.movil.assistant.AssistantSection
import dev.iyscode.movil.assistant.AssistantUi
import dev.iyscode.movil.assistant.AssistantViewModel
import dev.iyscode.movil.assistant.ContextNode
import dev.iyscode.movil.assistant.ContextPriority
import dev.iyscode.movil.assistant.GoogleOAuth
import dev.iyscode.movil.assistant.GoogleService
import dev.iyscode.movil.assistant.GraphLinkKind
import dev.iyscode.movil.assistant.GraphNode
import dev.iyscode.movil.assistant.GraphNodeKind
import dev.iyscode.movil.assistant.GraphPoint
import dev.iyscode.movil.assistant.LogLevel
import dev.iyscode.movil.assistant.QuickAction
import dev.iyscode.movil.assistant.QuickActionKind
import dev.iyscode.movil.assistant.Retrieval
import dev.iyscode.movil.assistant.SemanticContext
import dev.iyscode.movil.assistant.ToolMode
import dev.iyscode.movil.assistant.TreeFolder
import java.text.DateFormat
import java.util.Date
import kotlin.math.sqrt

// Asistente: Google, memoria semántica y el monitor de tu PC.
// Por defecto se ve sencillo; el registro y el corpus de tools aparecen al
// activar el modo desarrollador en Opciones. Misma estructura que
// Sources/Assistant/AssistantViews.swift en iOS.

@Composable
fun AssistantRoot(vm: AssistantViewModel, onSignIn: (String) -> Unit, onAppearanceChanged: () -> Unit) {
    val ui by vm.ui.collectAsState()
    val memory by vm.memory.nodes.collectAsState()
    val context = LocalContext.current
    val sections = AssistantCatalog.sections(ui.developerMode)

    Column(Modifier.fillMaxSize().imePadding()) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            sections.forEach { section ->
                Pill(section.title, selected = ui.section == section, onClick = { vm.open(section) })
            }
        }
        ui.message?.let { MessageBanner(it, onDismiss = vm::dismissMessage) }
        Box(Modifier.weight(1f)) {
            when (ui.section) {
                AssistantSection.HOME -> HomeSection(vm, ui, memory.size) { query -> openMaps(context, query) }
                AssistantSection.MEMORY -> MemorySection(vm, ui, memory)
                AssistantSection.GOOGLE -> GoogleSection(vm, ui, onSignIn)
                AssistantSection.LOG -> LogSection(vm, ui)
                AssistantSection.OPTIONS -> OptionsSection(vm, ui, onAppearanceChanged)
            }
        }
    }

    ui.pending?.let { action ->
        AlertDialog(
            onDismissRequest = { if (!ui.running) vm.cancelPending() },
            title = { Text(action.title, style = MaterialTheme.typography.titleMedium) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Muted(action.message)
                    action.details.forEach { (label, value) ->
                        Column {
                            Text(label.uppercase(), style = MaterialTheme.typography.labelSmall, color = Iys.textFaint)
                            Text(value, style = MaterialTheme.typography.bodyMedium, maxLines = 8, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    if (ui.developerMode) Muted("Tool: ${action.toolId}", Iys.textFaint)
                }
            },
            confirmButton = {
                Button(onClick = vm::confirmPending, enabled = !ui.running) {
                    if (ui.running) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Iys.onAccent)
                    else Text("Confirmar")
                }
            },
            dismissButton = { TextButton(onClick = vm::cancelPending, enabled = !ui.running) { Text("Cancelar") } },
        )
    }
}

private fun openMaps(context: Context, query: String) {
    val geo = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(query.ifBlank { "cerca de mí" })))
    try {
        context.startActivity(geo)
    } catch (_: ActivityNotFoundException) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps/search/?api=1&query=" + Uri.encode(query))))
    }
}

// ── Building blocks ─────────────────────────────────────────────────────────

@Composable
private fun Pill(text: String, selected: Boolean, onClick: () -> Unit, icon: ImageVector? = null) {
    Row(
        Modifier
            .background(if (selected) Iys.accent else Iys.surface, RoundedCornerShape(50))
            .border(1.dp, if (selected) Iys.accent else Iys.border, RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let { Icon(it, null, tint = if (selected) Iys.onAccent else Iys.textSecondary, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(6.dp)) }
        Text(text, style = MaterialTheme.typography.labelLarge, color = if (selected) Iys.onAccent else Iys.textPrimary)
    }
}

@Composable
private fun MessageBanner(text: String, onDismiss: () -> Unit) {
    Row(
        Modifier.padding(horizontal = 12.dp, vertical = 4.dp).fillMaxWidth()
            .background(Iys.accentSoft, RoundedCornerShape(12.dp)).padding(start = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).padding(vertical = 10.dp))
        IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, "Cerrar", tint = Iys.textSecondary) }
    }
}

@Composable
private fun SectionTitle(title: String, subtitle: String? = null, trailing: @Composable (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            subtitle?.let { Muted(it) }
        }
        trailing?.invoke()
    }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, singleLine: Boolean = true, modifier: Modifier = Modifier.fillMaxWidth()) {
    OutlinedTextField(
        value = value, onValueChange = onChange, modifier = modifier, singleLine = singleLine, maxLines = if (singleLine) 1 else 5,
        label = { Text(label, style = MaterialTheme.typography.bodySmall) },
        textStyle = MaterialTheme.typography.bodyMedium.copy(color = Iys.textPrimary),
        shape = RoundedCornerShape(12.dp),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Iys.accent, unfocusedBorderColor = Iys.border, cursorColor = Iys.accent,
            focusedLabelColor = Iys.accent, unfocusedLabelColor = Iys.textSecondary),
    )
}

@Composable
private fun ToggleRow(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.weight(1f).padding(end = 8.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Muted(detail)
        }
        Switch(checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Iys.accent, checkedThumbColor = Iys.onAccent))
    }
}

private fun time(millis: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(millis))

private fun serviceIcon(service: GoogleService?): ImageVector = when (service) {
    GoogleService.GMAIL -> Icons.Filled.Mail
    GoogleService.CALENDAR -> Icons.Filled.Event
    GoogleService.TASKS -> Icons.Filled.TaskAlt
    GoogleService.DRIVE, GoogleService.DOCS, GoogleService.SHEETS -> Icons.Filled.Folder
    GoogleService.CONTACTS -> Icons.Filled.Hub
    GoogleService.CLASSROOM -> Icons.Filled.AccountTree
    null -> Icons.Filled.Psychology
}

private fun priorityColor(priority: ContextPriority): Color = when (priority) {
    ContextPriority.CRITICAL -> Iys.red
    ContextPriority.HIGH -> Iys.orange
    ContextPriority.NORMAL -> Iys.blue
}

// ── Inicio ──────────────────────────────────────────────────────────────────

@Composable
private fun HomeSection(vm: AssistantViewModel, ui: AssistantUi, memoryCount: Int, onMaps: (String) -> Unit) {
    var prompt by rememberSaveable { mutableStateOf("") }
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Column(
                Modifier.fillMaxWidth()
                    .background(Brush.linearGradient(listOf(Iys.accent.copy(alpha = 0.22f), Iys.violet.copy(alpha = 0.20f))), RoundedCornerShape(24.dp))
                    .border(1.dp, Iys.border, RoundedCornerShape(24.dp))
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(if (ui.email != null) "Hola, ${ui.email.substringBefore('@')}" else "Hola", style = MaterialTheme.typography.headlineSmall)
                Muted("Tu correo, agenda, pendientes y lo que pasa en tu PC, en un solo lugar. Nada se envía ni se cambia sin que lo confirmes.")
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusChip(if (ui.signedIn) "Google conectado" else "Google sin conectar", if (ui.signedIn) Iys.green else Iys.textFaint)
                    StatusChip("PC: ${ui.monitorStatus}", if (ui.monitorStatus.startsWith("Conectado")) Iys.green else Iys.textFaint)
                    StatusChip("$memoryCount en memoria", Iys.violet)
                }
            }
        }
        item {
            Card {
                Text("¿Qué necesitas?", style = MaterialTheme.typography.titleMedium)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Field(prompt, { prompt = it }, "Ej. revisa mi agenda de hoy · busca un café cerca", modifier = Modifier.weight(1f))
                    Spacer(Modifier.width(8.dp))
                    Box(
                        Modifier.size(44.dp).background(if (prompt.isNotBlank()) Iys.accent else Iys.surfaceHigh, CircleShape)
                            .clickable(enabled = prompt.isNotBlank()) {
                                vm.ask(prompt)?.let(onMaps)
                                prompt = ""
                            },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.AutoMirrored.Filled.Send, "Enviar", tint = if (prompt.isNotBlank()) Iys.onAccent else Iys.textFaint, modifier = Modifier.size(18.dp)) }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Pill(if (ui.priorityContext) "Contexto prioritario: sí" else "Contexto prioritario", ui.priorityContext,
                        onClick = { vm.setPriorityContext(!ui.priorityContext) }, icon = Icons.Filled.AutoAwesome)
                }
                if (ui.priorityContext) Muted("Lo que envíes se propondrá para tu memoria con prioridad crítica, y GUS lo tendrá más en cuenta.")
            }
        }
        item { SectionTitle("Acciones rápidas", "Un toque y listo") }
        items(AssistantCatalog.quickActions.chunked(2)) { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                pair.forEach { action ->
                    QuickActionCard(action, ui.developerMode, Modifier.weight(1f)) { vm.runQuickAction(action)?.let(onMaps) }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        item { SectionTitle("Avisos", if (ui.feed.isEmpty()) null else "Lo más reciente primero") }
        if (ui.feed.isEmpty()) {
            item {
                Card {
                    Muted("Aún no hay avisos. Aquí aparecerán las tareas que termine tu PC, los correos nuevos (si activas la vigilancia) y lo que confirmes.")
                }
            }
        }
        items(ui.feed, key = { it.id }) { item ->
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.source, style = MaterialTheme.typography.labelSmall, color = Iys.accent, modifier = Modifier.weight(1f))
                    Muted(time(item.time), Iys.textFaint)
                }
                Text(item.title, style = MaterialTheme.typography.labelLarge)
                if (item.body.isNotBlank()) Muted(item.body)
            }
        }
    }
}

@Composable
private fun StatusChip(text: String, color: Color) {
    Row(
        Modifier.background(Iys.bgBase.copy(alpha = 0.7f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(color, CircleShape))
        Spacer(Modifier.width(6.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun QuickActionCard(action: QuickAction, developer: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val icon = when (action.kind) {
        QuickActionKind.OPEN_MAPS -> Icons.Filled.Place
        QuickActionKind.SAVE_MEMORY -> Icons.Filled.Psychology
        QuickActionKind.REFRESH_SERVICE -> serviceIcon(action.service)
    }
    Column(
        modifier.background(Iys.bgBase, RoundedCornerShape(18.dp)).border(1.dp, Iys.border, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(34.dp).background(Iys.accentSoft, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Iys.accent, modifier = Modifier.size(18.dp))
        }
        Text(action.title, style = MaterialTheme.typography.labelLarge)
        Muted(if (developer) action.toolId else action.subtitle)
    }
}

// ── Memoria ─────────────────────────────────────────────────────────────────

private const val HISTORY_KEY = "memorySearchHistory"

@Composable
private fun MemorySection(vm: AssistantViewModel, ui: AssistantUi, nodes: List<ContextNode>) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("assistant", Context.MODE_PRIVATE) }
    var query by rememberSaveable { mutableStateOf("") }
    var graphView by rememberSaveable { mutableStateOf(false) }
    val history = remember { mutableStateListOf<String>().apply { addAll(prefs.getString(HISTORY_KEY, "").orEmpty().split('\n').filter { it.isNotBlank() }) } }
    fun addHistory(term: String) {
        val clean = term.trim()
        if (clean.length < 2) return
        history.remove(clean); history.add(0, clean)
        while (history.size > 8) history.removeAt(history.lastIndex)
        prefs.edit().putString(HISTORY_KEY, history.joinToString("\n")).apply()
    }
    val matches = SemanticContext.fuzzyFilter(nodes, query)
    val visible = matches.map { it.node }

    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Card {
                Text("Memoria de GUS", style = MaterialTheme.typography.titleMedium)
                Muted("Lo que guardas se ordena en carpetas de tres niveles. Al preguntar, GUS recorre solo la rama que viene al caso: tarda un poco más, pero acierta más, sobre todo con modelos pequeños.")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Field(query, { query = it }, "Buscar (tolera errores: \"calndario\", \"swft\")", modifier = Modifier.weight(1f))
                    if (query.isNotEmpty()) IconButton(onClick = { addHistory(query); query = "" }) { Icon(Icons.Filled.Close, "Limpiar", tint = Iys.textSecondary) }
                }
                if (query.isNotBlank()) {
                    Muted("${visible.size} de ${nodes.size} coinciden")
                    LaunchedEffect(query) { kotlinx.coroutines.delay(1500); addHistory(query) }
                }
                if (history.isNotEmpty()) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.History, "Historial", tint = Iys.textFaint, modifier = Modifier.size(16.dp))
                        history.forEach { term -> Pill(term, selected = term == query, onClick = { query = term }) }
                        TextButton(onClick = { history.clear(); prefs.edit().remove(HISTORY_KEY).apply() }) { Text("Borrar historial") }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Pill("Carpetas", !graphView, onClick = { graphView = false }, icon = Icons.Filled.Folder)
                    Pill("Grafo", graphView, onClick = { graphView = true }, icon = Icons.Filled.Hub)
                }
            }
        }
        if (nodes.isEmpty()) {
            item { Card { Muted("Todavía no hay notas. Guarda la primera abajo, o toca \"Guardar en memoria\" bajo una respuesta de GUS.") } }
        } else if (graphView) {
            item { SemanticGraphCard(visible) }
        } else {
            val tree = SemanticContext.buildTree(visible)
            treeItems(tree, expandAll = query.isNotBlank(), developer = ui.developerMode, onDelete = vm::deleteMemory)
        }
        item { SaveMemoryCard(vm) }
        item { RetrievalProbe(vm, nodes.isNotEmpty()) }
    }
}

private fun LazyListScope.treeItems(folders: List<TreeFolder>, expandAll: Boolean, developer: Boolean, onDelete: (ContextNode) -> Unit) {
    folders.forEach { folder -> item(key = "folder-" + folder.fullPath.joinToString("/")) { FolderView(folder, expandAll, developer, onDelete) } }
}

@Composable
private fun FolderView(folder: TreeFolder, expandAll: Boolean, developer: Boolean, onDelete: (ContextNode) -> Unit) {
    var open by rememberSaveable(folder.fullPath.joinToString("/")) { mutableStateOf(folder.depth == 1) }
    val expanded = open || expandAll
    val levelName = when (folder.depth) { 1 -> "Dominio"; 2 -> "Rama"; else -> "Subtema" }
    Column(Modifier.padding(start = ((folder.depth - 1) * 14).dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { open = !open }.padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (expanded) Icons.Filled.ExpandMore else Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                tint = Iys.textSecondary, modifier = Modifier.size(18.dp))
            Icon(Icons.Filled.Folder, null, tint = if (folder.depth == 1) Iys.violet else Iys.accent, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(folder.name, style = if (folder.depth == 1) MaterialTheme.typography.titleMedium else MaterialTheme.typography.labelLarge,
                modifier = Modifier.weight(1f))
            Muted(if (developer) "$levelName · ${folder.totalNodes} · ~${folder.totalTokens} tok" else "${folder.totalNodes}", Iys.textFaint)
        }
        if (expanded) {
            folder.subfolders.forEach { FolderView(it, expandAll, developer, onDelete) }
            folder.nodes.forEach { node -> MemoryNodeCard(node, developer, onDelete) }
        }
    }
}

@Composable
private fun MemoryNodeCard(node: ContextNode, developer: Boolean, onDelete: (ContextNode) -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    Column(
        Modifier.padding(start = 14.dp, top = 4.dp, bottom = 4.dp).fillMaxWidth()
            .background(Iys.bgBase, RoundedCornerShape(14.dp)).border(1.dp, Iys.border, RoundedCornerShape(14.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).background(priorityColor(node.priority), CircleShape))
            Spacer(Modifier.width(6.dp))
            Text(node.title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = { confirm = true }, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Filled.Delete, "Borrar", tint = Iys.textFaint, modifier = Modifier.size(16.dp))
            }
        }
        Muted(node.summary)
        Muted(if (developer) "${node.priority.label} · ${node.source} · ~${node.estimatedTokens} tok" else node.priority.label, Iys.textFaint)
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("¿Borrar esta nota?") },
            text = { Text("GUS dejará de usarla. No se puede deshacer.") },
            confirmButton = { Button(onClick = { confirm = false; onDelete(node) }) { Text("Borrar") } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancelar") } },
        )
    }
}

@Composable
private fun SaveMemoryCard(vm: AssistantViewModel) {
    var title by rememberSaveable { mutableStateOf("") }
    var summary by rememberSaveable { mutableStateOf("") }
    var level1 by rememberSaveable { mutableStateOf("") }
    var level2 by rememberSaveable { mutableStateOf("") }
    var level3 by rememberSaveable { mutableStateOf("") }
    var priority by rememberSaveable { mutableStateOf(ContextPriority.HIGH) }
    val suggested = SemanticContext.inferPath("$title $summary")
    Card {
        Text("Guardar una nota", style = MaterialTheme.typography.titleMedium)
        Field(title, { title = it }, "Título (opcional)")
        Field(summary, { summary = it }, "Qué debe recordar GUS", singleLine = false)
        Muted("Carpeta sugerida: ${suggested.joinToString(" › ")}. Cámbiala si quieres:")
        Field(level1, { level1 = it }, "Dominio · ${suggested[0]}")
        Field(level2, { level2 = it }, "Rama · ${suggested.getOrElse(1) { "" }}")
        Field(level3, { level3 = it }, "Subtema · ${suggested.getOrElse(2) { "" }}")
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ContextPriority.entries.forEach { p -> Pill(p.label, priority == p, onClick = { priority = p }) }
        }
        Button(onClick = {
            val path = listOf(level1.ifBlank { suggested[0] }, level2.ifBlank { suggested.getOrElse(1) { "" } }, level3.ifBlank { suggested.getOrElse(2) { "" } })
            vm.proposeMemory(title, summary, path, priority, "manual")
            title = ""; summary = ""; level1 = ""; level2 = ""; level3 = ""
        }, enabled = summary.isNotBlank()) { Text("Guardar…") }
    }
}

@Composable
private fun RetrievalProbe(vm: AssistantViewModel, hasNodes: Boolean) {
    var probe by rememberSaveable { mutableStateOf("") }
    var result by remember { mutableStateOf<Retrieval?>(null) }
    Card {
        Text("Probar qué usaría GUS", style = MaterialTheme.typography.titleMedium)
        Muted("Escribe una pregunta y verás la rama que recorre y las notas que elige.")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Field(probe, { probe = it }, "Ej. ¿cuándo es mi junta de equipo?", modifier = Modifier.weight(1f))
            IconButton(onClick = { result = vm.previewRetrieval(probe) }, enabled = probe.isNotBlank() && hasNodes) {
                Icon(Icons.Filled.Search, "Probar", tint = Iys.accent)
            }
        }
        result?.let { r ->
            r.steps.forEachIndexed { i, step ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(18.dp).background(Iys.accentSoft, CircleShape), contentAlignment = Alignment.Center) {
                        Text("${i + 1}", style = MaterialTheme.typography.labelSmall, color = Iys.accent)
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(step, style = MaterialTheme.typography.bodySmall)
                }
            }
            r.nodes.forEach { Muted("• ${it.title}", priorityColor(it.priority)) }
        }
    }
}

// ── Graph (Obsidian-style) ──────────────────────────────────────────────────

@Composable
private fun SemanticGraphCard(nodes: List<ContextNode>) {
    val graph = remember(nodes) { SemanticContext.buildGraph(nodes) }
    val positions = remember(graph) { mutableStateMapOf<String, GraphPoint>().apply { putAll(SemanticContext.layout(graph)) } }
    var scale by remember { mutableStateOf(1f) }
    var pan by remember(graph) { mutableStateOf(Offset.Zero) }
    var selectedId by remember(graph) { mutableStateOf<String?>(null) }
    var showLegend by rememberSaveable { mutableStateOf(true) }
    var bridgesOnly by rememberSaveable { mutableStateOf(false) }
    var layoutSeed by remember { mutableStateOf(0) }
    val measurer = rememberTextMeasurer()
    // Layout coordinates are in dp; the canvas draws in pixels.
    val px = LocalDensity.current.density
    val byId = graph.nodes.associateBy { it.id }
    val neighbors = selectedId?.let { id -> graph.links.filter { it.source == id || it.target == id }.flatMap { listOf(it.source, it.target) }.toSet() }
    val labelColor = Iys.textPrimary
    val faint = Iys.textFaint

    fun nodeColor(node: GraphNode): Color = when (node.kind) {
        GraphNodeKind.DOMAIN -> Iys.violet
        GraphNodeKind.CLUSTER -> Iys.accent
        GraphNodeKind.CONTEXT -> priorityColor(node.priority)
    }

    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Constelación", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            IconButton(onClick = { scale = (scale / 1.25f).coerceAtLeast(0.4f) }) { Icon(Icons.Filled.Remove, "Alejar", tint = Iys.textSecondary) }
            Muted("${(scale * 100).toInt()}%")
            IconButton(onClick = { scale = (scale * 1.25f).coerceAtMost(3f) }) { Icon(Icons.Filled.Add, "Acercar", tint = Iys.textSecondary) }
        }
        Muted("Arrastra los círculos para acomodarlos, arrastra el fondo para moverte y toca uno para ver su detalle.")
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Pill("Todo", !bridgesOnly, onClick = { bridgesOnly = false })
            Pill("Solo puentes", bridgesOnly, onClick = { bridgesOnly = true })
            Pill(if (showLegend) "Ocultar leyenda" else "Leyenda", showLegend, onClick = { showLegend = !showLegend })
            Pill("Reorganizar", false, onClick = {
                layoutSeed += 1
                positions.clear(); positions.putAll(SemanticContext.layout(graph, seed = layoutSeed))
                pan = Offset.Zero; scale = 1f
            })
        }
        Box(
            Modifier.fillMaxWidth().height(360.dp)
                .background(if (Iys.dark) Color(0xFF0D0D16) else Color(0xFFF1EFF7), RoundedCornerShape(16.dp))
                .border(1.dp, Iys.border, RoundedCornerShape(16.dp)),
        ) {
            var canvas by remember { mutableStateOf(IntSize.Zero) }
            fun toScreen(p: GraphPoint) = Offset(canvas.width / 2f + (p.x + pan.x) * scale * px, canvas.height / 2f + (p.y + pan.y) * scale * px)
            fun hit(offset: Offset): GraphNode? = graph.nodes.minByOrNull { node ->
                val s = toScreen(positions[node.id] ?: GraphPoint(0f, 0f))
                (s - offset).getDistance()
            }?.takeIf { node ->
                val s = toScreen(positions[node.id] ?: GraphPoint(0f, 0f))
                (s - offset).getDistance() <= (node.radius / 2.2f + 10) * px * scale.coerceAtLeast(0.8f)
            }
            var dragging by remember { mutableStateOf<String?>(null) }
            Canvas(
                Modifier.fillMaxSize()
                    .onSizeChanged { canvas = it }
                    .pointerInput(graph) {
                        detectTapGestures(onTap = { offset -> selectedId = hit(offset)?.id })
                    }
                    .pointerInput(graph) {
                        detectDragGestures(
                            onDragStart = { offset -> dragging = hit(offset)?.id },
                            onDragEnd = { dragging = null },
                            onDragCancel = { dragging = null },
                        ) { change, amount ->
                            change.consume()
                            val id = dragging
                            if (id != null) {
                                val p = positions[id] ?: GraphPoint(0f, 0f)
                                positions[id] = GraphPoint(p.x + amount.x / (scale * px), p.y + amount.y / (scale * px))
                            } else {
                                pan += Offset(amount.x / (scale * px), amount.y / (scale * px))
                            }
                        }
                    },
            ) {
                // Domain halos first, so everything else sits on top.
                graph.nodes.filter { it.kind == GraphNodeKind.DOMAIN }.forEach { hub ->
                    val members = graph.nodes.filter { it.domain == hub.domain }.mapNotNull { positions[it.id] }
                    if (members.isNotEmpty()) {
                        val cx = members.map { it.x }.average().toFloat()
                        val cy = members.map { it.y }.average().toFloat()
                        val reach = members.maxOf { sqrt((it.x - cx) * (it.x - cx) + (it.y - cy) * (it.y - cy)) } + 40f
                        drawCircle(nodeColor(hub).copy(alpha = 0.07f), reach * scale * px, toScreen(GraphPoint(cx, cy)))
                    }
                }
                graph.links.forEach { link ->
                    if (bridgesOnly && link.kind == GraphLinkKind.HIERARCHY) return@forEach
                    val a = positions[link.source] ?: return@forEach
                    val b = positions[link.target] ?: return@forEach
                    val lit = selectedId == null || link.source == selectedId || link.target == selectedId
                    val semantic = link.kind == GraphLinkKind.SEMANTIC
                    drawLine(
                        color = (if (semantic) Iys.yellow else faint).copy(alpha = if (lit) 0.85f else 0.15f),
                        start = toScreen(a), end = toScreen(b), strokeWidth = (if (semantic) 1.6f else 1.2f) * density,
                        pathEffect = if (semantic) PathEffect.dashPathEffect(floatArrayOf(10f, 8f)) else null,
                    )
                }
                graph.nodes.forEach { node ->
                    val p = positions[node.id] ?: return@forEach
                    val center = toScreen(p)
                    val dim = neighbors != null && node.id !in neighbors
                    val color = nodeColor(node).copy(alpha = if (dim) 0.25f else 1f)
                    val r = node.radius * scale * density / 2.2f
                    if (node.kind == GraphNodeKind.CONTEXT) {
                        drawCircle(color, r, center)
                    } else {
                        drawCircle(color.copy(alpha = if (dim) 0.08f else 0.18f), r, center)
                        drawCircle(color, r, center, style = Stroke(width = 2f * density))
                    }
                    if (node.id == selectedId) drawCircle(labelColor, r + 4 * density, center, style = Stroke(width = 1.5f * density))
                    val showLabel = node.kind != GraphNodeKind.CONTEXT || node.id == selectedId || scale >= 1.2f || neighbors?.contains(node.id) == true
                    if (showLabel && !dim) {
                        val label = if (node.label.length > 22) node.label.take(20) + "…" else node.label
                        val layout = measurer.measure(label, TextStyle(fontSize = 10.sp, color = labelColor,
                            fontWeight = if (node.kind == GraphNodeKind.DOMAIN) FontWeight.Bold else FontWeight.Normal))
                        drawText(layout, topLeft = Offset(center.x - layout.size.width / 2f, center.y + r + 3 * density))
                    }
                }
            }
        }
        if (showLegend) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                LegendRow(Iys.red, "Crítica")
                LegendRow(Iys.orange, "Alta")
                LegendRow(Iys.blue, "Normal")
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                LegendRow(Iys.violet, "Dominio", ring = true)
                LegendRow(Iys.accent, "Rama", ring = true)
                LegendRow(Iys.yellow, "Puente", dashed = true)
            }
        }
        Muted("${graph.nodes.count { it.kind == GraphNodeKind.CONTEXT }} notas · ${graph.links.count { it.kind == GraphLinkKind.SEMANTIC }} puentes", Iys.textFaint)
        selectedId?.let { byId[it] }?.let { node ->
            HorizontalDivider(color = Iys.border)
            Text(node.label, style = MaterialTheme.typography.titleMedium)
            Muted(node.path.joinToString(" › "), Iys.accent)
            Muted(node.summary)
            val related = graph.links.filter { it.source == node.id || it.target == node.id }
            if (related.isNotEmpty()) {
                Text("Conectado con", style = MaterialTheme.typography.labelLarge)
                related.forEach { link ->
                    val other = byId[if (link.source == node.id) link.target else link.source] ?: return@forEach
                    Row(Modifier.fillMaxWidth().clickable { selectedId = other.id }.padding(vertical = 3.dp)) {
                        Text(other.label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Muted(if (link.kind == GraphLinkKind.SEMANTIC) link.label else "carpeta", Iys.textFaint)
                    }
                }
            }
        }
    }
}

@Composable
private fun LegendRow(color: Color, label: String, ring: Boolean = false, dashed: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.size(width = 14.dp, height = 10.dp)) {
            when {
                dashed -> drawLine(color, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = 3f,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 4f)))
                ring -> drawCircle(color, size.height / 2.4f, style = Stroke(width = 3f))
                else -> drawCircle(color, size.height / 2.2f)
            }
        }
        Spacer(Modifier.width(6.dp))
        Text(label, style = MaterialTheme.typography.bodySmall)
    }
}

// ── Google ──────────────────────────────────────────────────────────────────

@Composable
private fun GoogleSection(vm: AssistantViewModel, ui: AssistantUi, onSignIn: (String) -> Unit) {
    val context = LocalContext.current
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Card {
                Text(if (ui.signedIn) "Cuenta de Google" else "Conecta tu cuenta de Google", style = MaterialTheme.typography.titleMedium)
                if (ui.signedIn) {
                    Muted(ui.email ?: "Conectada")
                    Muted("Permisos: " + GoogleService.entries.filter { ui.granted(it) }.joinToString { it.title }.ifEmpty { "ninguno" })
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = vm::refreshAll) { Text("Actualizar todo") }
                        OutlinedButton(onClick = { vm.beginSignIn()?.let(onSignIn) }) { Text("Cambiar permisos") }
                        TextButton(onClick = vm::signOut) { Text("Desconectar") }
                    }
                } else {
                    Muted("Inicias sesión en la página de Google, con tu propio proyecto. El token se queda en este teléfono y puedes desconectarlo cuando quieras.")
                    Button(onClick = { vm.beginSignIn()?.let(onSignIn) }) { Text("Iniciar sesión con Google") }
                    if (!GoogleOAuth.isPlausibleClientId(ui.clientId)) Muted("Antes, pega tu ID de cliente en Opciones › Google.", Iys.orange)
                }
            }
        }
        if (!ui.signedIn) return@LazyColumn
        val active = GoogleService.entries.filter { it in ui.enabledServices }
        active.forEach { service ->
            item(key = service.name) {
                ServiceCard(vm, ui, service) { url -> context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            }
        }
    }
}

@Composable
private fun ServiceCard(vm: AssistantViewModel, ui: AssistantUi, service: GoogleService, openUrl: (String) -> Unit) {
    val granted = ui.granted(service)
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(serviceIcon(service), null, tint = Iys.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(service.title, style = MaterialTheme.typography.titleMedium)
                Muted(service.detail)
            }
            if (service != GoogleService.DOCS && granted) {
                if (service in ui.loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Iys.accent)
                else IconButton(onClick = { vm.refresh(service) }) { Icon(Icons.Filled.Refresh, "Actualizar", tint = Iys.textSecondary) }
            }
        }
        if (!granted) {
            Muted("Sin permiso todavía. Toca \"Cambiar permisos\" arriba.", Iys.orange)
            return@Card
        }
        when (service) {
            GoogleService.GMAIL -> {
                ui.mail.forEach { m ->
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Text(m.subject, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Muted(m.from, Iys.textFaint)
                        Muted(m.snippet)
                    }
                }
                ComposeMail(vm)
            }
            GoogleService.CALENDAR -> {
                ui.events.forEach { e ->
                    Row(Modifier.fillMaxWidth().clickable(enabled = e.link.isNotEmpty()) { openUrl(e.link) }.padding(vertical = 4.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(e.title, style = MaterialTheme.typography.labelLarge)
                            Muted(e.start.replace('T', ' ').take(16) + if (e.location.isNotBlank()) " · ${e.location}" else "")
                        }
                    }
                }
                NewEvent(vm)
            }
            GoogleService.TASKS -> {
                ui.tasks.forEach { t -> Text("• ${t.title}", style = MaterialTheme.typography.bodyMedium) }
                var title by rememberSaveable { mutableStateOf("") }
                var notes by rememberSaveable { mutableStateOf("") }
                Field(title, { title = it }, "Nuevo pendiente")
                Field(notes, { notes = it }, "Notas (opcional)")
                Button(onClick = { vm.proposeTask(title, notes); title = ""; notes = "" }, enabled = title.isNotBlank()) { Text("Agregar…") }
            }
            GoogleService.DRIVE -> ui.files.forEach { f ->
                Row(Modifier.fillMaxWidth().clickable(enabled = f.link.isNotEmpty()) { openUrl(f.link) }.padding(vertical = 4.dp)) {
                    Text(f.name, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Muted(f.modified.take(10), Iys.textFaint)
                }
            }
            GoogleService.DOCS -> {
                var title by rememberSaveable { mutableStateOf("") }
                var text by rememberSaveable { mutableStateOf("") }
                Field(title, { title = it }, "Título del documento")
                Field(text, { text = it }, "Contenido", singleLine = false)
                Button(onClick = { vm.proposeDoc(title, text); title = ""; text = "" }, enabled = title.isNotBlank()) { Text("Crear…") }
            }
            GoogleService.CONTACTS -> ui.contacts.forEach { c ->
                Column(Modifier.padding(vertical = 3.dp)) {
                    Text(c.name.ifEmpty { c.email }, style = MaterialTheme.typography.labelLarge)
                    Muted(listOf(c.email, c.organization).filter { it.isNotBlank() }.joinToString(" · "))
                }
            }
            GoogleService.SHEETS -> {
                var sheet by rememberSaveable { mutableStateOf(ui.sheetId) }
                Field(sheet, { sheet = it; vm.setSheetId(it) }, "Enlace o ID de la hoja")
                ui.sheet?.let { data ->
                    Muted("Pestaña: ${data.tab}", Iys.textFaint)
                    data.rows.take(10).forEach { row -> Text(row.joinToString("  |  "), style = MaterialTheme.typography.labelSmall) }
                }
                var values by rememberSaveable { mutableStateOf("") }
                Field(values, { values = it }, "Nueva fila, separada por comas")
                Button(onClick = { vm.proposeRow(values.split(',').map { it.trim() }); values = "" }, enabled = values.isNotBlank()) { Text("Agregar fila…") }
            }
            GoogleService.CLASSROOM -> {
                var text by rememberSaveable { mutableStateOf("") }
                ui.courses.forEach { course ->
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Text(course.name, style = MaterialTheme.typography.labelLarge)
                        if (course.section.isNotBlank()) Muted(course.section)
                        TextButton(onClick = { vm.proposeAnnouncement(course, text) }, enabled = text.isNotBlank()) { Text("Publicar anuncio aquí…") }
                    }
                }
                if (ui.courses.isNotEmpty()) Field(text, { text = it }, "Anuncio", singleLine = false)
            }
        }
    }
}

@Composable
private fun ComposeMail(vm: AssistantViewModel) {
    var open by rememberSaveable { mutableStateOf(false) }
    if (!open) { TextButton(onClick = { open = true }) { Text("Redactar correo") }; return }
    var to by rememberSaveable { mutableStateOf("") }
    var subject by rememberSaveable { mutableStateOf("") }
    var body by rememberSaveable { mutableStateOf("") }
    Field(to, { to = it }, "Para")
    Field(subject, { subject = it }, "Asunto")
    Field(body, { body = it }, "Mensaje", singleLine = false)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { vm.proposeEmail(to, subject, body) }, enabled = to.isNotBlank()) { Text("Enviar…") }
        TextButton(onClick = { open = false }) { Text("Cerrar") }
    }
}

@Composable
private fun NewEvent(vm: AssistantViewModel) {
    var open by rememberSaveable { mutableStateOf(false) }
    if (!open) { TextButton(onClick = { open = true }) { Text("Nuevo evento") }; return }
    var title by rememberSaveable { mutableStateOf("") }
    var date by rememberSaveable { mutableStateOf(java.time.LocalDate.now().toString()) }
    var time by rememberSaveable { mutableStateOf("10:00") }
    var minutes by rememberSaveable { mutableStateOf("45") }
    var location by rememberSaveable { mutableStateOf("") }
    Field(title, { title = it }, "Título")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Field(date, { date = it }, "Fecha (AAAA-MM-DD)", modifier = Modifier.weight(1.3f))
        Field(time, { time = it }, "Hora", modifier = Modifier.weight(0.8f))
        Field(minutes, { minutes = it.filter(Char::isDigit) }, "Min", modifier = Modifier.weight(0.6f))
    }
    Field(location, { location = it }, "Lugar (opcional)")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { vm.proposeEvent(title, date, time, minutes.toIntOrNull() ?: 45, location) }, enabled = title.isNotBlank()) { Text("Crear…") }
        TextButton(onClick = { open = false }) { Text("Cerrar") }
    }
}

// ── Registro (developer) ────────────────────────────────────────────────────

@Composable
private fun LogSection(vm: AssistantViewModel, ui: AssistantUi) {
    val context = LocalContext.current
    var filter by rememberSaveable { mutableStateOf<LogLevel?>(null) }
    val entries = ui.logs.filter { filter == null || it.level == filter }
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        item {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Pill("Todo", filter == null, onClick = { filter = null })
                LogLevel.entries.forEach { level -> Pill(level.name, filter == level, onClick = { filter = level }) }
                TextButton(onClick = vm::clearLogs) { Text("Limpiar") }
            }
        }
        if (entries.isEmpty()) item { Card { Muted("Sin eventos con este filtro.") } }
        items(entries, key = { it.id }) { entry ->
            val color = when (entry.level) {
                LogLevel.ERROR -> Iys.red
                LogLevel.SUCCESS -> Iys.green
                LogLevel.TOOL -> Iys.violet
                LogLevel.INFO -> Iys.textSecondary
            }
            Column(
                Modifier.fillMaxWidth().background(Iys.bgBase, RoundedCornerShape(12.dp))
                    .border(1.dp, if (entry.level == LogLevel.ERROR) Iys.red.copy(alpha = 0.5f) else Iys.border, RoundedCornerShape(12.dp))
                    .padding(10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Badge(entry.level.name, color)
                    Spacer(Modifier.width(6.dp))
                    Text(entry.tool, style = MaterialTheme.typography.labelSmall, color = Iys.textSecondary, modifier = Modifier.weight(1f))
                    Muted(time(entry.time), Iys.textFaint)
                }
                Text(entry.message, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 4.dp))
                Row {
                    TextButton(onClick = { copy(context, entry.rawJson()) }) {
                        Icon(Icons.Filled.ContentCopy, null, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(4.dp)); Text("Copiar")
                    }
                    if (entry.retryable) TextButton(onClick = { vm.retry(entry) }) {
                        Icon(Icons.Filled.Replay, null, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(4.dp)); Text("Reintentar")
                    }
                }
            }
        }
    }
}

// ── Opciones ────────────────────────────────────────────────────────────────

@Composable
private fun OptionsSection(vm: AssistantViewModel, ui: AssistantUi, onAppearanceChanged: () -> Unit) {
    val context = LocalContext.current
    var notificationsAllowed by remember { mutableStateOf(vm.notifier.canPost()) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { notificationsAllowed = it }
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Card {
                Text("Apariencia", style = MaterialTheme.typography.titleMedium)
                Muted("Automático sigue el modo claro u oscuro de tu teléfono.")
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Appearance.entries.forEach { a ->
                        Pill(a.label, ui.appearance == a, onClick = { if (vm.setAppearance(a)) onAppearanceChanged() })
                    }
                }
            }
        }
        item {
            Card {
                Text("Notificaciones", style = MaterialTheme.typography.titleMedium)
                Muted(if (notificationsAllowed) "Activadas: te avisaremos de tareas de tu PC, correos nuevos y acciones confirmadas."
                      else "Desactivadas. Actívalas para recibir avisos.")
                if (!notificationsAllowed && Build.VERSION.SDK_INT >= 33) {
                    Button(onClick = { permission.launch(Manifest.permission.POST_NOTIFICATIONS) }) {
                        Icon(Icons.Filled.NotificationsActive, null, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("Permitir avisos")
                    }
                }
            }
        }
        item { MonitorCard(vm, ui) }
        item { GoogleSetupCard(vm, ui) }
        item {
            Card {
                ToggleRow("Modo desarrollador", "Muestra el registro de eventos, el corpus de tools y los detalles técnicos.",
                    ui.developerMode, vm::setDeveloperMode)
            }
        }
        if (ui.developerMode) {
            item { SectionTitle("Corpus de tools", "Lo que GUS y cualquier modelo conectado pueden usar") }
            items(AssistantCatalog.tools, key = { it.id }) { tool ->
                Row(
                    Modifier.fillMaxWidth().background(Iys.bgBase, RoundedCornerShape(12.dp)).border(1.dp, Iys.border, RoundedCornerShape(12.dp)).padding(10.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(serviceIcon(tool.service), null, tint = Iys.accent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(tool.id, style = MaterialTheme.typography.labelSmall, color = Iys.textPrimary)
                        Muted(tool.description)
                        Muted(tool.endpoint, Iys.textFaint)
                    }
                    Badge(tool.mode.label, if (tool.mode == ToolMode.WRITE_CONFIRMED) Iys.orange else Iys.green)
                }
            }
        }
    }
}

@Composable
private fun MonitorCard(vm: AssistantViewModel, ui: AssistantUi) {
    var url by rememberSaveable { mutableStateOf(ui.monitorUrl) }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Bolt, null, tint = Iys.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Tu PC (iSyCode / IsyMCP)", style = MaterialTheme.typography.titleMedium)
        }
        Muted("El daemon de tu PC publica sus tareas en un archivo JSON (por ejemplo en raw.githubusercontent.com). El teléfono lo revisa cada 30 segundos mientras la app está abierta y te avisa de lo nuevo.")
        Field(url, { url = it }, "https://raw.githubusercontent.com/tu-usuario/…/tareas.json")
        ToggleRow("Vigilar el manifiesto", "Estado: ${ui.monitorStatus}", ui.monitorEnabled) { vm.configureMonitor(url, it, ui.watchGmail) }
        ToggleRow("Avisarme de correos nuevos", if (ui.granted(GoogleService.GMAIL)) "Revisa Gmail cada minuto" else "Requiere conectar Gmail",
            ui.watchGmail) { vm.configureMonitor(url, ui.monitorEnabled, it) }
        if (url != ui.monitorUrl) Button(onClick = { vm.configureMonitor(url, ui.monitorEnabled, ui.watchGmail) }) { Text("Guardar dirección") }
    }
}

@Composable
private fun GoogleSetupCard(vm: AssistantViewModel, ui: AssistantUi) {
    var clientId by rememberSaveable { mutableStateOf(ui.clientId) }
    Card {
        Text("Google", style = MaterialTheme.typography.titleMedium)
        Muted("1. En console.cloud.google.com crea un ID de cliente OAuth de tipo Android con el paquete dev.iyscode.movil y activa \"Esquema de URI personalizado\".\n2. Habilita las APIs que quieras usar (Gmail, Calendar, Tasks…).\n3. Pega aquí el ID de cliente. La guía completa está en docs/GOOGLE_ASSISTANT.md.")
        Field(clientId, { clientId = it }, "ID de cliente (….apps.googleusercontent.com)")
        if (clientId != ui.clientId) Button(onClick = { vm.setClientId(clientId) }) { Text("Guardar") }
        Text("Servicios que pediremos", style = MaterialTheme.typography.labelLarge)
        GoogleService.entries.forEach { service ->
            ToggleRow(service.title, service.detail, service in ui.enabledServices) { vm.toggleService(service, it) }
        }
        if (ui.signedIn) Muted("Si cambias los servicios, toca \"Cambiar permisos\" en la sección Google.", Iys.textFaint)
    }
}
