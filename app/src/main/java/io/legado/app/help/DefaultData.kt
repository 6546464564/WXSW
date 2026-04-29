package io.legado.app.help

import io.legado.app.data.appDb
import io.legado.app.data.entities.DictRule
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.HttpTTS
import io.legado.app.data.entities.KeyboardAssist
import io.legado.app.data.entities.RssSource
import io.legado.app.data.entities.TxtTocRule
import io.legado.app.help.config.LocalConfig
import io.legado.app.help.config.ReadBookConfig
import io.legado.app.help.config.ThemeConfig
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.model.BookCover
import io.legado.app.utils.GSON
import io.legado.app.utils.fromJsonArray
import io.legado.app.utils.fromJsonObject
import io.legado.app.utils.printOnDebug
import splitties.init.appCtx
import java.io.File

object DefaultData {

    fun upVersion() {
        // 万象书屋: 不再依赖外层 versionCode 比较 (debug 构建 versionCode 经常重复),
        // 每个 needUpXxx 内部自带 isLastVersion 版本号管理,改为始终进入并独立判定
        Coroutine.async {
            if (LocalConfig.needUpHttpTTS) {
                importDefaultHttpTTS()
            }
            if (LocalConfig.needUpTxtTocRule) {
                importDefaultTocRules()
            }
            if (LocalConfig.needUpRssSources) {
                importDefaultRssSources()
            }
            if (LocalConfig.needUpBookSources) {
                importDefaultBookSources()
            }
            if (LocalConfig.needUpDictRule) {
                importDefaultDictRules()
            }
        }.onError {
            it.printOnDebug()
        }
    }

    val httpTTS: List<HttpTTS> by lazy {
        val json =
            String(
                appCtx.assets.open("defaultData${File.separator}httpTTS.json")
                    .readBytes()
            )
        HttpTTS.fromJsonArray(json).getOrElse {
            emptyList()
        }
    }

    val readConfigs: List<ReadBookConfig.Config> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}${ReadBookConfig.configFileName}")
                .readBytes()
        )
        GSON.fromJsonArray<ReadBookConfig.Config>(json).getOrNull()
            ?: emptyList()
    }

    val txtTocRules: List<TxtTocRule> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}txtTocRule.json")
                .readBytes()
        )
        GSON.fromJsonArray<TxtTocRule>(json).getOrNull() ?: emptyList()
    }

    val themeConfigs: List<ThemeConfig.Config> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}${ThemeConfig.configFileName}")
                .readBytes()
        )
        GSON.fromJsonArray<ThemeConfig.Config>(json).getOrNull() ?: emptyList()
    }

    val rssSources: List<RssSource> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}rssSources.json")
                .readBytes()
        )
        GSON.fromJsonArray<RssSource>(json).getOrDefault(emptyList())
    }

    val bookSources: List<BookSource> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}bookSources.json")
                .readBytes()
        )
        GSON.fromJsonArray<BookSource>(json).getOrDefault(emptyList())
    }

    val coverRule: BookCover.CoverRule by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}coverRule.json")
                .readBytes()
        )
        GSON.fromJsonObject<BookCover.CoverRule>(json).getOrThrow()
    }

    val dictRules: List<DictRule> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}dictRules.json")
                .readBytes()
        )
        GSON.fromJsonArray<DictRule>(json).getOrThrow()
    }

    val keyboardAssists: List<KeyboardAssist> by lazy {
        val json = String(
            appCtx.assets.open("defaultData${File.separator}keyboardAssists.json")
                .readBytes()
        )
        GSON.fromJsonArray<KeyboardAssist>(json).getOrThrow()
    }

    fun importDefaultHttpTTS() {
        appDb.httpTTSDao.deleteDefault()
        appDb.httpTTSDao.insert(*httpTTS.toTypedArray())
    }

    fun importDefaultTocRules() {
        appDb.txtTocRuleDao.deleteDefault()
        appDb.txtTocRuleDao.insert(*txtTocRules.toTypedArray())
    }

    fun importDefaultRssSources() {
        appDb.rssSourceDao.deleteDefault()
        appDb.rssSourceDao.insert(*rssSources.toTypedArray())
    }

    /**
     * 万象书屋: 已废弃的内置书源 URL 列表
     * 升级时主动从用户 DB 中删除,避免「书源已不可用但仍残留」的体验问题
     */
    /**
     * 万象书屋: 已知失效/反爬/验证码/过期的内置书源 URL 黑名单
     * 升级时主动从用户 DB 中删除,避免「书源已不可用但仍残留」的体验问题
     * 50 条来自 2026-04-29 全量探测 (CLOUDFLARE/CAPTCHA/ERR_403/TIMEOUT/BAD_URL)
     */
    private val disabledBookSourceUrls = listOf(
        // 之前手动剔除的
        "https://www.banzhu44444.com/",
        "https://www.99csw.com",
        // === 2026-04-29 自动探测剔除 ===
        "# 洛制的爱丽丝书屋！",
        "http://18hdm.com/",
        "http://wap.shukuge.com",
        "http://www.337939.com",
        "http://www.biquge.site",
        "http://www.sequge.com",
        "http://www.shukuge.com/",
        "http://www.x81zws.com/",
        "https://99shuba.feelingapi.com/",
        "https://api.qiubai.icu",
        "https://api-x.shrtxs.cn/qd/",
        "https://book.qingse.site/",
        "https://fqnovels.indevs.in/",
        "https://lt.aqxsw888.com/",
        "https://m.newqy.com/",
        "https://m.qidian.com#我的书架",
        "https://m.s1wl.com/",
        "https://m.zdzn.net",
        "https://manwaai.cc/",
        "https://novel.snssdk.com",
        "https://wap.haitangshuwu.info",
        "https://www.69shuba.com",
        "https://www.biquge.tw",
        "https://www.bz33333333.com/",
        "https://www.bz444444.net",
        "https://www.bz88888.net////##",
        "https://www.cuoceng.com",
        "https://www.dbxsd.com/",
        "https://www.gequbao.com",
        "https://www.gudaibook1.com",
        "https://www.huanmengacg.com",
        "https://www.kanzh.com/",
        "https://www.kelexs.com/",
        "https://www.libahao.com",
        "https://www.oop.tw",
        "https://www.piaotia.com",
        "https://www.qidian.com",
        "https://www.sudugu.org",
        "https://www.szncb.com",
        "https://www.tongrenxsw.com",
        "https://www.uaa001.com",
        "https://www.xn--7dv141d.com/",
        "https://www.xsuuu.cc",
        "https://www.yiyechunxiao.com",
        "https://xingmian.cmcure.com",
        "📖Lofter",
        "哔哩哔哩",
        "订阅源",
        "看书阁",
        "找书",
    )

    fun importDefaultBookSources() {
        val sources = bookSources
        if (sources.isNotEmpty()) {
            appDb.bookSourceDao.insert(*sources.toTypedArray())
        }
        disabledBookSourceUrls.forEach { url ->
            appDb.bookSourceDao.delete(url)
        }
    }

    fun importDefaultDictRules() {
        appDb.dictRuleDao.insert(*dictRules.toTypedArray())
    }

}