package io.legado.app.ui.about

import android.os.Bundle
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import io.legado.app.databinding.ActivityAccountDeleteFinishedBinding
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlin.system.exitProcess

/**
 * 万象书屋: 注销成功的"完成页".
 *
 * 之前 AccountDeleteActivity 在 wipe 完成 800ms 后直接 killProcess, 用户视角
 * 是"应用突然消失", 不知道操作是否成功.
 *
 * 现在改成: wipe 完后跳到本页, 全屏文案告诉用户"已成功清除", 提供一个明显的
 * 「退出应用」按钮, 用户主动点 = kill 进程. 拦截 Back 键避免回到已被清空的主界面.
 *
 * 注意:
 *   - 这个 Activity 启动时 Room 已经被 close, 所有 SP 已被 commit clear,
 *     所以**不能**调用任何 db / SP 的代码. UI 全部静态.
 *   - 主题用 NoActionBar 让顶部更简洁
 */
class AccountDeleteFinishedActivity : AppCompatActivity() {

    private val binding by viewBinding(ActivityAccountDeleteFinishedBinding::inflate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)

        // 万象书屋: 拦 Back 键, 让 Back 等于"退出应用", 防止用户回到已经清空数据的主界面
        // 看到崩溃 / 空状态.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { exitApp() }
        })

        binding.btnExit.setOnClickListener { exitApp() }
    }

    private fun exitApp() {
        finishAffinity()
        // 给 Activity 动画一点点时间
        binding.btnExit.postDelayed({
            android.os.Process.killProcess(android.os.Process.myPid())
            exitProcess(0)
        }, 200)
    }
}
