import XCTest
@testable import WanxiangBook

/// 书源兼容性测试：验证书源解析规则的正确性和容错性
final class BookSourceCompatTests: XCTestCase {

    func test_allEnabledSourcesLoadable() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources
        NSLog("[BookSource] 已加载 %d 个书源", sources.count)

        for source in sources where source.enabled {
            XCTAssertFalse(source.bookSourceUrl.isEmpty,
                "书源 \(source.bookSourceName) 的 URL 不应为空")
            XCTAssertFalse(source.bookSourceName.isEmpty,
                "书源 URL=\(source.bookSourceUrl) 的名称不应为空")
        }
    }

    func test_searchRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        var withSearchRule = 0
        for source in sources where source.enabled {
            if let rule = source.ruleSearch, !(rule.bookList ?? "").isEmpty {
                withSearchRule += 1
            }
        }
        NSLog("[BookSource] %d/%d 个启用书源有搜索规则", withSearchRule, sources.filter(\.enabled).count)
    }

    func test_tocRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let toc = source.ruleToc {
                XCTAssertFalse((toc.chapterList ?? "").isEmpty,
                    "书源 \(source.bookSourceName) 目录规则chapterList不应为空")
            }
        }
    }

    func test_contentRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let content = source.ruleContent {
                XCTAssertFalse((content.content ?? "").isEmpty,
                    "书源 \(source.bookSourceName) 正文规则content不应为空")
            }
        }
    }

    func test_malformedSourceGracefulFailure() async {
        let malformed = BookSource(
            bookSourceUrl: "",
            bookSourceName: "MalformedTest",
            searchUrl: "{{invalid}}"
        )

        do {
            let results = try await BookSourceEngine.shared.search(
                in: malformed, key: "测试"
            )
            NSLog("[BookSource] 畸形书源搜索返回 %d 条结果 (应为空)", results.count)
        } catch {
            NSLog("[BookSource] 畸形书源搜索正确抛出异常: %@", error.localizedDescription)
        }
    }

    func test_emptyBookSourceDefaults() {
        let source = BookSource(bookSourceUrl: "", bookSourceName: "")
        XCTAssertTrue(source.bookSourceUrl.isEmpty)
        XCTAssertTrue(source.bookSourceName.isEmpty)
        XCTAssertNil(source.ruleSearch)
        XCTAssertNil(source.ruleToc)
        XCTAssertNil(source.ruleContent)
    }

    func test_sourceGroupParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        let groups = Set(sources.compactMap(\.bookSourceGroup))
        NSLog("[BookSource] 书源分组: %@", groups.joined(separator: ", "))
    }

    func test_topSourcesSearch() async {
        let registry = await BookSourceRegistry.shared
        await registry.waitUntilEnabledSourcesNonEmpty(timeout: 15)
        let sources = await registry.sources.filter(\.enabled).prefix(3)

        for source in sources {
            do {
                let results = try await BookSourceEngine.shared.search(
                    in: source, key: "测试"
                )
                NSLog("[BookSource] %@ 搜索返回 %d 条结果",
                      source.bookSourceName, results.count)
            } catch {
                NSLog("[BookSource] %@ 搜索失败: %@",
                      source.bookSourceName, error.localizedDescription)
            }
        }
    }

    func test_h5book_search() async throws {
        let jsLib = """
        var HMAC_KEY='1234567890123456';var BASE='https://h5.h5bookyyds.com';function genHeaders(){var ts=''+java.lang.System.currentTimeMillis();var nonce=java.util.UUID.randomUUID().toString().replace(/-/g,'').substring(0,32);var ks=new javax.crypto.spec.SecretKeySpec(java.lang.String(HMAC_KEY).getBytes('UTF-8'),'HmacSHA256');var mac=javax.crypto.Mac.getInstance('HmacSHA256');mac.init(ks);var sb=mac.doFinal(java.lang.String(ts+'.'+nonce).getBytes('UTF-8'));var sig='';for(var i=0;i<sb.length;i++){var b=sb[i]&0xFF;sig+=(b<16?'0':'')+java.lang.Integer.toHexString(b);}return{'x-timestamp':ts,'x-nonce':nonce,'x-signature':sig};}function decrypt(hex){hex=(''+hex).trim();var len=hex.length/2;var d=java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE,len);for(var i=0;i<len;i++){var v=java.lang.Integer.parseInt(hex.substring(i*2,i*2+2),16);d[i]=v>127?v-256:v;}var kb=java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE,32);for(var i=0;i<32;i++){var x=((d[48+i]&0xFF)^(d[i]&0xFF));kb[i]=x>127?x-256:x;}var iv=java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE,16);for(var i=0;i<16;i++){var x=((d[80+i]&0xFF)^(d[32+i]&0xFF));iv[i]=x>127?x-256:x;}var cl=len-96;var cb=java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE,cl);java.lang.System.arraycopy(d,96,cb,0,cl);var cipher=javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');cipher.init(javax.crypto.Cipher.DECRYPT_MODE,new javax.crypto.spec.SecretKeySpec(kb,'AES'),new javax.crypto.spec.IvParameterSpec(iv));return''+new java.lang.String(cipher.doFinal(cb),'UTF-8');}
        """
        var rule = SearchRule()
        rule.bookList = "@js:JSON.parse(decrypt(result)).book"
        rule.name = "$.name"
        rule.author = "$.author"
        rule.bookUrl = "@js:var item=(typeof result==='string')?JSON.parse(result):result;BASE+'/d-aDUuaDVib29reXlkcy5jb20=/book/'+item.book_id"

        var source = BookSource(
            bookSourceUrl: "https://h5.h5bookyyds.com",
            bookSourceName: "H5Book",
            searchUrl: "@js:BASE+'/api/search/list?keyword='+encodeURIComponent(key)",
            ruleSearch: rule
        )
        source.jsLib = jsLib
        source.header = "@js:JSON.stringify(genHeaders())"

        let results = try await BookSourceEngine.shared.search(in: source, key: "青山")
        NSLog("[H5Book-test] search returned %d results", results.count)
        for r in results.prefix(3) {
            NSLog("[H5Book-test] name=%@ author=%@ url=%@", r.name, r.author, r.bookUrl)
        }
        XCTAssertGreaterThan(results.count, 0, "H5Book should return search results for 青山")
    }

    func test_sudugu_search() async throws {
        var rule = SearchRule()
        rule.bookList = "class.item"
        rule.name = "class.itemtxt@tag.h3@tag.a@text"
        rule.author = "class.itemtxt@tag.p.1@tag.a@text"
        rule.bookUrl = "class.itemtxt@tag.h3@tag.a@href"

        let source = BookSource(
            bookSourceUrl: "https://www.sudugu.org",
            bookSourceName: "速读谷",
            searchUrl: "/i/sor.aspx?key={{key}}",
            ruleSearch: rule
        )

        let results = try await BookSourceEngine.shared.search(in: source, key: "青山")
        NSLog("[sudugu-test] search returned %d results", results.count)
        for r in results.prefix(3) {
            NSLog("[sudugu-test] name=%@ author=%@ url=%@", r.name, r.author, r.bookUrl)
        }
        XCTAssertGreaterThan(results.count, 0, "速读谷 should return search results for 青山")
    }

    func test_all_remote_sources_search() async throws {
        let url = URL(string: "https://www.wxsw.app/api/sources")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode([BookSource].self, from: data)
        let searchable = decoded.filter { $0.searchUrl != nil && !($0.searchUrl?.isEmpty ?? true) && $0.bookSourceUrl != "https://www.wxsw.app" }
        NSLog("[all-sources] loaded %d searchable sources from API", searchable.count)

        for source in searchable {
            do {
                let results = try await BookSourceEngine.shared.search(in: source, key: "青山")
                NSLog("[all-sources] %@ → %d results", source.bookSourceName, results.count)
                if results.isEmpty {
                    NSLog("[all-sources] WARNING: %@ returned 0 results!", source.bookSourceName)
                }
            } catch {
                NSLog("[all-sources] %@ → ERROR: %@", source.bookSourceName, String(describing: error).prefix(120) as CVarArg)
            }
        }
    }
}
