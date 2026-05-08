package io.legado.app.utils

/**
 * 万象书屋 D-16 (PARSE-1): 可被线程中断的 CharSequence 包装.
 *
 * 解决问题:
 *   `java.util.regex.Pattern.matcher(...).replaceAll(...)` 是同步阻塞调用, **不响应 Thread.interrupt()**.
 *   当用户书源里有 `(a+)+` / `(.+)+@(.+)+` 这类 ReDoS 模式 + 内容含 30 字以上连续字符时,
 *   一次 replace 可冻结协程数秒到数分钟, 整个阅读流程卡死.
 *
 * 原理:
 *   Pattern matcher 内部对每个字符调用 charAt(i). 我们在 charAt 里加一行
 *   `if (Thread.interrupted()) throw RuntimeException(...)`,
 *   一旦 watchdog/timeout 调 Thread.interrupt(), 下一次 charAt 就会抛异常,
 *   matcher 立即解开堆栈退出回溯.
 *
 * 用法 (在 AnalyzeRule.replaceRegex 中):
 *   ```
 *   runBlocking(coroutineContext) {
 *     withTimeoutOrNull(REGEX_TIMEOUT_MS) {
 *       runInterruptible(Dispatchers.Default) {
 *         pattern.matcher(InterruptibleCharSequence(input)).replaceAll(replacement)
 *       }
 *     } ?: input  // 超时则放弃替换, 返回原内容
 *   }
 *   ```
 *
 * 这是 Java 社区 (Guava / Apache Lucene) 标准做法, 不引入新依赖, 0 性能开销
 * (charAt 本来就是 hot path, 多一个 volatile 读 ~纳秒级).
 */
class InterruptibleCharSequence(private val inner: CharSequence) : CharSequence {

    override val length: Int get() = inner.length

    override fun get(index: Int): Char {
        // 任何时候被 Thread.interrupt() 标记, 下次访问字符即抛 → matcher 退出
        if (Thread.interrupted()) {
            throw RegexInterruptedException()
        }
        return inner[index]
    }

    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
        return InterruptibleCharSequence(inner.subSequence(startIndex, endIndex))
    }

    override fun toString(): String = inner.toString()
}

/** 万象书屋: 专用异常类型, 让 replaceRegex catch 时能区分 ReDoS 中断 vs 真正 bug */
class RegexInterruptedException : RuntimeException("regex matching interrupted (likely ReDoS timeout)")
