package com.micago.message.mica_go

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** PackageManager is the source of truth; no second preference can drift after an update. */
internal class LauncherIcons(private val context: Context) {
    private val aliases = linkedMapOf(
        "default" to "DefaultIcon",
        "classic" to "ClassicIcon",
        "minimal" to "MinimalIcon",
    )

    private fun component(alias: String) =
        ComponentName(context.packageName, "${context.packageName}.$alias")

    fun current(): String = aliases.keys.firstOrNull { id ->
        val state = context.packageManager.getComponentEnabledSetting(component(aliases.getValue(id)))
        state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
            (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && id == "default")
    } ?: error("No launcher icon is enabled")

    fun select(id: String): String {
        require(id in aliases) { "Unknown launcher icon" }
        val manager = context.packageManager
        val states = aliases.map { (key, alias) ->
            component(alias) to if (key == id) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.setComponentEnabledSettings(states.map { (name, state) ->
                PackageManager.ComponentEnabledSetting(name, state, PackageManager.DONT_KILL_APP)
            })
        } else {
            // Enable the destination first, so an interrupted swap never removes every entry.
            val previous = states.map { (name, _) -> name to manager.getComponentEnabledSetting(name) }
            val ordered = states.sortedBy { if (it.second == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) 0 else 1 }
            try {
                ordered.forEach { (name, state) ->
                    manager.setComponentEnabledSetting(name, state, PackageManager.DONT_KILL_APP)
                }
            } catch (error: Exception) {
                // Best-effort rollback, enabling the former icon before removing the new one.
                previous.sortedBy { (name, state) ->
                    if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                        (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && name == component("DefaultIcon"))) 0 else 1
                }.forEach { (name, state) ->
                    runCatching { manager.setComponentEnabledSetting(name, state, PackageManager.DONT_KILL_APP) }
                }
                throw error
            }
        }
        return current()
    }
}
