package io.legado.app

import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import org.intellij.lang.annotations.Language
import org.junit.Assert
import org.junit.Test

class AndroidJsTest {

    @Test
    fun testMap() {
        val map = hashMapOf("id" to "3242532321")
        val bindings = ScriptBindings()
        bindings["result"] = map
        @Language("js")
        val jsMap = "$=result;id=$.id;id"
        val result = RhinoScriptEngine.eval(jsMap, bindings)
        Assert.assertEquals("3242532321", result)
        @Language("js")
        val jsMap1 = """result.get("id")"""
        val result1 = RhinoScriptEngine.eval(jsMap1, bindings)
        Assert.assertEquals("3242532321", result1)
    }

    @Test
    fun testHmacSign() {
        // 书源常用的阿里云签名: 验证 JS 引擎能访问 javax.crypto 做 HmacSHA1
        // 注意: 必须走带 bindings 的 eval 路径 (与产品 BaseSource/SharedJsScope 一致),
        // 无参 eval(js) 的 ExternalScriptable 对 ConsString 处理有 bug, 产品不使用该路径.
        @Language("js")
        val js = """
            var Mac = Packages.javax.crypto.Mac;
            var SecretKeySpec = Packages.javax.crypto.spec.SecretKeySpec;
            var mac = Mac.getInstance('HmacSHA1');
            var keyBytes = new Packages.java.lang.String('key').getBytes('UTF-8');
            mac.init(new SecretKeySpec(keyBytes, 'HmacSHA1'));
            var data = mac.doFinal(new Packages.java.lang.String('hello').getBytes('UTF-8'));
            var hex = '';
            for (var i = 0; i < data.length; i++) {
                var b = data[i] & 0xFF;
                hex += (b < 16 ? '0' : '') + b.toString(16);
            }
            hex
        """.trimIndent()
        val result = RhinoScriptEngine.eval(js, ScriptBindings())
        Assert.assertEquals(
            "b34ceac4516ff23a143e61d79d0fa7a4fbe5f266",
            result
        )
    }

    @Test
    fun testBase64() {
        // 书源常用的 Base64 编解码 (android.util.Base64)
        @Language("js")
        val js = """
            var bytes = new Packages.java.lang.String('hello').getBytes('UTF-8');
            Packages.android.util.Base64.encodeToString(bytes, 2)
        """.trimIndent()
        val result = RhinoScriptEngine.eval(js, ScriptBindings())
        Assert.assertEquals("aGVsbG8=", result)
    }

}