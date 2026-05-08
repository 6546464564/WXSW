package io.legado.app.help.update

/**
 * 万象书屋: 上游 legado 的 GitHub 自更新模块已被移除 (国内应用商店禁止 App 内
 * 自更新, 必须走商店渠道). 这里只保留 AppVariant 枚举, 因为 AppConst.kt 仍用
 * 它来识别"我是 official / beta / 还是其它构建", 与网络无关.
 *
 * 已删除:
 *   - AppUpdate.kt          - 自更新接口
 *   - AppUpdateGitHub.kt    - GitHub release 拉取实现
 *   - AppReleaseInfo data class / Asset / GithubRelease - GitHub API DTO
 */
enum class AppVariant {
    OFFICIAL,
    BETA_RELEASEA,
    BETA_RELEASE,
    UNKNOWN;

    fun isBeta(): Boolean {
        return this == BETA_RELEASE || this == BETA_RELEASEA
    }
}
