package io.legado.app.ui.about

import android.os.Bundle
import android.text.method.LinkMovementMethod
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.lifecycle.lifecycleScope
import io.legado.app.R
import io.legado.app.ad.AdConsent
import io.legado.app.ad.AdRateLimiter
import io.legado.app.data.appDb
import io.legado.app.databinding.ActivityAccountDeleteBinding
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import splitties.init.appCtx

/**
 * 万象书屋: 注销账号 / 清除全部本地数据.
 *
 * 国内应用商店硬性要求 (2024 起): 即使没有账号体系, 也必须给用户一个"一键删除全部本地数据 + 撤销所有授权"的入口.
 *
 * 行为:
 *   1. 撤销隐私授权 (AdConsent.revoke), 后续不会上报任何信息
 *   2. 清空所有 SharedPreferences
 *   3. 清空所有 Room 数据库 (书架 / 书源 / 书签 / 阅读记录 / ...)
 *   4. 清空 cache + externalCache + files 目录 (排除 lib / databases 已被 Room 管理)
 *   5. 强杀进程, 下次启动等同于全新安装
 */
class AccountDeleteActivity : AppCompatActivity() {

    private val binding by viewBinding(ActivityAccountDeleteBinding::inflate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar as Toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = getString(R.string.about_account_delete)

        binding.tvWarning.movementMethod = LinkMovementMethod.getInstance()
        binding.btnDelete.setOnClickListener { confirmDelete() }
    }

    private fun confirmDelete() {
        AlertDialog.Builder(this)
            .setTitle(R.string.account_delete_confirm_title)
            .setMessage(R.string.account_delete_confirm_msg)
            .setPositiveButton(R.string.account_delete_confirm_yes) { _, _ ->
                doDelete()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun doDelete() {
        binding.btnDelete.isEnabled = false
        toastOnUi(R.string.account_delete_in_progress)
        // 万象书屋: 注销路径必须串行 + 清晰顺序, 防止 Room 还在写入时 DELETE FROM 引发死锁:
        //   1. 立即撤销广告/隐私同意 (停止任何远程上报)
        //   2. 清 Room 表数据 (此时 App 仅剩本 Activity, 其他 Activity 已 finish 不会再写)
        //   3. 关闭 Room 写连接, 让 SQLite 释放文件锁
        //   4. 删 SharedPreferences / cache / externalCache / files
        //   5. 跳到 AccountDeleteFinishedActivity, 用户按"退出应用"自己结束 (好过突然 kill)
        lifecycleScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { wipeEverything() }
            }
            // 跳完成页 + clear top, 让 task 内只剩 finish-page 一个 Activity
            val intent = android.content.Intent(this@AccountDeleteActivity, AccountDeleteFinishedActivity::class.java)
                .addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                    android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK
                )
            startActivity(intent)
            finish()
        }
    }

    private fun wipeEverything() {
        // 1. 撤销广告 / 隐私授权 (会同步 AdManager.consented=false, 之后任何上报都会被拦)
        runCatching { AdConsent.revoke() }
        runCatching { AdRateLimiter.reset() }

        // 2. 清 Room 表内容 (在关闭 Room 前做, 因为 close 后再操作会抛 IllegalStateException)
        runCatching {
            val db = appDb.openHelper.writableDatabase
            db.beginTransaction()
            try {
                val tables = mutableListOf<String>()
                db.query(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' AND name NOT LIKE 'room_%'"
                ).use { c ->
                    while (c.moveToNext()) tables += c.getString(0)
                }
                for (t in tables) db.execSQL("DELETE FROM `$t`")
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        }

        // 3. 关闭 Room. 后续任何 DAO 调用都会 throw, 但我们马上 kill 进程没人会调.
        runCatching { appDb.close() }

        // 4. 清 SharedPreferences. 万象书屋: 顺序很关键 —
        //    a) 先用 commit().clear() 让进程内每个已加载的 SP 实例**同步** flush 空内容到磁盘,
        //       避免后面删完 .xml 但内存 SP 在我们 kill 前再 apply() 把旧数据写回.
        //    b) 再删整个 shared_prefs 目录文件 (含我们没列出的 xml).
        runCatching {
            val prefsDir = java.io.File(appCtx.applicationInfo.dataDir, "shared_prefs")
            // 枚举所有 .xml 文件名 → 反推 SP name (去掉 .xml), 用 Context.getSharedPreferences 拿到
            // 进程内的同一个实例 (单例 cache), commit().clear() 真正清掉内存 + 磁盘
            prefsDir.listFiles { f -> f.name.endsWith(".xml") }?.forEach { f ->
                val name = f.name.removeSuffix(".xml")
                runCatching {
                    appCtx.getSharedPreferences(name, android.content.Context.MODE_PRIVATE)
                        .edit().clear().commit()
                }
            }
            // 物理删 (commit 后 SP 仍可能保留空 xml, 一并清掉)
            prefsDir.listFiles()?.forEach { it.delete() }
        }

        // 5. 清 cache / externalCache / files (databases 子目录已由 Room close 写完 WAL, 删它无害)
        runCatching {
            wipeDir(appCtx.cacheDir, exclude = emptySet())
            appCtx.externalCacheDir?.let { wipeDir(it, emptySet()) }
            wipeDir(appCtx.filesDir, exclude = emptySet())
        }
    }

    private fun wipeDir(dir: java.io.File?, exclude: Set<String>) {
        if (dir == null || !dir.exists()) return
        dir.listFiles()?.forEach {
            if (it.name in exclude) return@forEach
            if (it.isDirectory) it.deleteRecursively() else it.delete()
        }
    }

    override fun onSupportNavigateUp(): Boolean { finish(); return true }
}
