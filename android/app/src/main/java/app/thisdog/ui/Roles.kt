package app.thisdog.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.thisdog.data.Account
import app.thisdog.data.Api
import app.thisdog.data.Graph
import app.thisdog.data.Member
import app.thisdog.data.NotifyKind
import app.thisdog.i18n.L
import app.thisdog.model.Day
import kotlinx.coroutines.launch

/** „Wer kommt dazu?“ – vor dem Einladen. Hundesitter werden nicht gestört, Besitzer verwalten das Rudel. */
@Composable
fun RoleChoiceDialog(onDismiss: () -> Unit, onChoose: (String) -> Unit) {
    val p = LocalPalette.current
    AlertDialog(onDismiss, title = { Text(L.t("Wer kommt dazu?")) },
        text = { Text(L.t("Hundesitter sehen alles und tragen ein, bekommen aber nur Mitteilungen, die sie selbst einschalten. Besitzer bekommen alle Mitteilungen, laden ein und vergeben Rollen.")) },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                TextButton({ onChoose("sitter") }) { Text(L.t("Hundesitter"), color = p.accent, fontWeight = FontWeight.SemiBold) }
                TextButton({ onChoose("owner") }) { Text(L.t("Besitzer"), color = p.accent, fontWeight = FontWeight.SemiBold) }
                TextButton(onDismiss) { Text(L.t("Abbrechen"), color = p.ink2) }
            }
        })
}

/** Unter dem Namen in der Mitgliederliste: „Du · Besitzer“ oder „Hundesitter · seit 24. Aug.“ */
fun memberLine(m: Member, me: Int?): String {
    val since = Day(java.time.Instant.ofEpochSecond(m.joinedAt.toLong()).atZone(java.time.ZoneId.systemDefault()).toLocalDate()).shortText
    return if (m.id == me) L.t("Du · %1\$s", m.roleLabel) else L.t("%1\$s · seit %2\$s", m.roleLabel, since)
}

/**
 * Ein Mitglied: Rolle und Mitteilungen (wie MemberSheet.swift). Besitzer legen für jeden fest, welche Mitteilungen er
 * bekommen *darf*, und vergeben Rollen; jeder schaltet für sich ein, welche er *will*.
 */
@Composable
fun MemberDialog(memberId: Int, onDismiss: () -> Unit) {
    val p = LocalPalette.current; val a = Graph.account; val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var confirmRemove by remember { mutableStateOf(false) }
    val m = a.currentPack?.members?.firstOrNull { it.id == memberId } ?: return
    val isMe = m.id == a.me
    fun run(work: suspend () -> Unit) {
        working = true; message = null
        scope.launch {
            try { work() } catch (e: Exception) {
                message = when ((e as? Api.Failure.Server)?.code) {
                    "last_owner" -> L.t("Ein Rudel braucht mindestens einen Besitzer.")
                    "not_owner" -> L.t("Das dürfen nur Besitzer.")
                    "use_leave" -> L.t("Dich selbst nimmst du mit „Rudel verlassen“ heraus.")
                    "not_a_member" -> L.t("Diese Person ist nicht mehr im Rudel.")
                    else -> Account.message(e)
                }
            }
            working = false
        }
    }
    androidx.compose.ui.window.Dialog(onDismiss) {
        Column(Modifier.clip(RoundedCornerShape(28.dp)).background(p.paper).verticalScroll(rememberScrollState()).padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Title(if (isMe) L.t("Du im Rudel") else m.name, 24.sp)
            if (a.isOwner) {
                Text(L.t("Rolle"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(p.surface).padding(4.dp)) {
                    listOf("owner" to L.t("Besitzer"), "sitter" to L.t("Hundesitter")).forEach { (role, label) ->
                        val on = (role == "owner") == m.isOwner
                        Box(Modifier.weight(1f).clip(RoundedCornerShape(50)).background(if (on) p.accent else Color.Transparent)
                            .clickable(enabled = !on && !working) { run { a.setRole(role, m.id) } }.padding(vertical = 9.dp), contentAlignment = Alignment.Center) {
                            Text(label, color = if (on) Color.White else p.ink, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                        }
                    }
                }
                Text(if (m.isOwner) L.t("Besitzer laden ein, vergeben Rollen und legen fest, wer welche Mitteilungen bekommen darf.")
                    else L.t("Hundesitter sehen alles und tragen ein, bekommen aber nur Mitteilungen, die sie selbst einschalten."), fontSize = 13.sp, color = p.ink2)
            }
            if (isMe) {
                Text(L.t("Meine Mitteilungen"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                NotifyKind.entries.forEach { kind ->
                    val allowed = (m.notifyAllowed ?: emptyList()).contains(kind.key)
                    // Besitzer dürfen sich selbst alles erlauben; Hundesitter nur, was freigegeben ist.
                    val usable = allowed || m.isOwner
                    val on = allowed && (m.notifyWanted ?: emptyList()).contains(kind.key)
                    KindRow(kind.title, if (usable) kind.detail else L.t("Von den Besitzern nicht freigegeben."), on, usable && !working) { now ->
                        val wanted = (m.notifyWanted ?: emptyList()).toMutableSet().apply { if (now) add(kind.key) else remove(kind.key) }
                        val allow = if (now && !allowed && m.isOwner) NotifyKind.keys.filter { (m.notifyAllowed ?: emptyList()).contains(it) || it == kind.key } else null
                        run { a.setNotify(m.id, allowed = allow, wanted = NotifyKind.keys.filter(wanted::contains)) }
                    }
                }
                Text(L.t("Gilt für dieses Rudel. Ob Mitteilungen überhaupt erscheinen, legst du außerdem in den Einstellungen deines Telefons fest."), fontSize = 13.sp, color = p.ink3)
            } else if (a.isOwner) {
                Text(L.t("Darf Mitteilungen bekommen bei"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = p.ink2)
                NotifyKind.entries.forEach { kind ->
                    val on = (m.notifyAllowed ?: emptyList()).contains(kind.key)
                    KindRow(kind.title, kind.detail, on, !working) { now ->
                        val set = (m.notifyAllowed ?: emptyList()).toMutableSet().apply { if (now) add(kind.key) else remove(kind.key) }
                        run { a.setNotify(m.id, allowed = NotifyKind.keys.filter(set::contains)) }
                    }
                }
                val gets = m.notifies.map { it.title }
                Text(if (gets.isEmpty()) L.t("%1\$s bekommt gerade keine Mitteilungen. Einschalten kann %1\$s sie selbst.", m.name)
                    else L.t("%1\$s bekommt gerade: %2\$s. Was davon, entscheidet %1\$s selbst.", m.name, gets.joinToString(", ")), fontSize = 13.sp, color = p.ink3)
            }
            // Nur Besitzer, nur andere: Sich selbst nimmt man mit „Rudel verlassen“ heraus.
            if (a.isOwner && !isMe) Text(L.t("Aus dem Rudel entfernen"), color = p.health, fontSize = 15.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = !working) { confirmRemove = true }.padding(vertical = 6.dp))
            message?.let { Text(it, fontSize = 14.sp, color = p.health) }
            TextButton(onDismiss, Modifier.align(Alignment.End)) { Text(L.t("Fertig"), color = p.accent, fontWeight = FontWeight.SemiBold) }
        }
    }
    if (confirmRemove) AlertDialog({ confirmRemove = false }, title = { Text(L.t("%1\$s aus dem Rudel entfernen?", m.name)) },
        text = { Text(L.t("%1\$s kommt sofort nicht mehr an die gemeinsamen Daten und bekommt keine Änderungen mehr. Was schon auf dem Telefon von %1\$s liegt, bleibt dort.", m.name)) },
        confirmButton = { TextButton({ confirmRemove = false; run { a.remove(m.id); onDismiss() } }) { Text(L.t("Entfernen"), color = p.health) } },
        dismissButton = { TextButton({ confirmRemove = false }) { Text(L.t("Abbrechen")) } })
}

@Composable
private fun KindRow(title: String, detail: String, on: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(p.surface).padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = if (enabled) p.ink else p.ink3, fontWeight = FontWeight.SemiBold)
            Text(detail, fontSize = 13.sp, color = p.ink2)
        }
        Spacer(Modifier.width(10.dp))
        Switch(on, onChange, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = p.accent))
    }
}
