package com.ira.ira_service_desk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

/**
 * Phone ki incoming call pakadta hai (app band ho tab bhi).
 * RINGING -> state save + IRA app call screen ke upar kholo (Green / Red / Yellow).
 */
class CallReceiver : BroadcastReceiver() {
    companion object {
        const val PREFS = "ira_calls"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        @Suppress("DEPRECATION")
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val prev = prefs.getString("state", "IDLE")
        val edit = prefs.edit()
        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                val newCall = prev != "RINGING"
                edit.putString("state", "RINGING")
                if (newCall) {
                    edit.putLong("ts", System.currentTimeMillis())
                    edit.putString("number", number)
                } else if (number.isNotEmpty()) {
                    edit.putString("number", number)
                }
                edit.commit()
                if (newCall) openApp(context)
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> edit.putString("state", "OFFHOOK").commit()
            TelephonyManager.EXTRA_STATE_IDLE -> edit.putString("state", "IDLE").commit()
        }
    }

    private fun openApp(context: Context) {
        try {
            val i = Intent(context, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            context.startActivity(i)
        } catch (e: Exception) {
        }
    }
}
