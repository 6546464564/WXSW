package io.legado.app.model.webBook

import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.constant.PreferKey
import io.legado.app.data.appDb
import io.legado.app.data.entities.BookSourcePart
import io.legado.app.data.entities.SearchBook
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.config.AppConfig
import io.legado.app.ui.book.search.SearchScope
import io.legado.app.utils.getPrefBoolean
import io.legado.app.utils.mapParallelSafe
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import splitties.init.appCtx
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.coroutines.coroutineContext
import kotlin.math.min

class SearchModel(private val scope: CoroutineScope, private val callBack: CallBack) {
    val threadCount = AppConfig.threadCount
    private var searchPool: ExecutorCoroutineDispatcher? = null
    private var mSearchId = 0L
    private var searchPage = 1
    private var searchKey: String = ""
    private var bookSourceParts = emptyList<BookSourcePart>()
    private var searchBooks = arrayListOf<SearchBook>()
    private var searchJob: Job? = null
    private var workingState = MutableStateFlow(true)


    private fun initSearchPool() {
        searchPool?.close()
        searchPool = Executors
            .newFixedThreadPool(min(threadCount, AppConst.MAX_THREAD)).asCoroutineDispatcher()
    }

    fun search(searchId: Long, key: String) {
        if (searchId != mSearchId) {
            if (key.isEmpty()) {
                return
            }
            searchKey = key
            if (mSearchId != 0L) {
                close()
            }
            searchBooks.clear()
            bookSourceParts = callBack.getSearchScope().getBookSourceParts()
            if (bookSourceParts.isEmpty()) {
                callBack.onSearchCancel(NoStackTraceException("启用书源为空"))
                return
            }
            mSearchId = searchId
            searchPage = 1
            initSearchPool()
        } else {
            searchPage++
        }
        startSearch()
    }

    private fun startSearch() {
        val precision = appCtx.getPrefBoolean(PreferKey.precisionSearch)
        var hasMore = false
        searchJob = scope.launch(searchPool!!) {
            flow {
                for (bs in bookSourceParts) {
                    bs.getBookSource()?.let {
                        emit(it)
                    }
                    workingState.first { it }
                }
            }.onStart {
                callBack.onSearchStart()
            }.mapParallelSafe(threadCount) {
                withTimeout(30000L) {
                    WebBook.searchBookAwait(
                        it, searchKey, searchPage,
                        filter = { name, author ->
                            !precision || name.contains(searchKey) ||
                                    author.contains(searchKey)
                        })
                }
            }.onEach { items ->
                for (book in items) {
                    book.releaseHtmlData()
                }
                hasMore = hasMore || items.isNotEmpty()
                appDb.searchBookDao.insert(*items.toTypedArray())
                mergeItems(items, precision)
                currentCoroutineContext().ensureActive()
                callBack.onSearchSuccess(searchBooks)
            }.onCompletion {
                if (it == null) callBack.onSearchFinish(searchBooks.isEmpty(), hasMore)
            }.catch {
                // 万象书屋: 用户切换关键词或退出搜索时, 线程池关闭后被丢弃的并发任务会抛
                // RejectedExecutionException / CancellationException, 这是预期取消, 不写入用户日志
                if (it !is RejectedExecutionException && it !is CancellationException) {
                    AppLog.put("书源搜索出错\n${it.localizedMessage}", it)
                }
            }.collect()
        }
    }

    private suspend fun mergeItems(newDataS: List<SearchBook>, precision: Boolean) {
        if (newDataS.isNotEmpty()) {
            val copyData = ArrayList(searchBooks)
            val equalData = arrayListOf<SearchBook>()
            val containsData = arrayListOf<SearchBook>()
            val otherData = arrayListOf<SearchBook>()
            copyData.forEach {
                coroutineContext.ensureActive()
                if (it.name == searchKey || it.author == searchKey) {
                    equalData.add(it)
                } else if (it.name.contains(searchKey) || it.author.contains(searchKey)) {
                    containsData.add(it)
                } else {
                    otherData.add(it)
                }
            }
            newDataS.forEach { nBook ->
                coroutineContext.ensureActive()
                if (nBook.name == searchKey || nBook.author == searchKey) {
                    var hasSame = false
                    equalData.forEach { pBook ->
                        coroutineContext.ensureActive()
                        if (pBook.name == nBook.name && pBook.author == nBook.author) {
                            pBook.addOrigin(nBook.origin)
                            hasSame = true
                        }
                    }
                    if (!hasSame) {
                        equalData.add(nBook)
                    }
                } else if (nBook.name.contains(searchKey) || nBook.author.contains(searchKey)) {
                    var hasSame = false
                    containsData.forEach { pBook ->
                        coroutineContext.ensureActive()
                        if (pBook.name == nBook.name && pBook.author == nBook.author) {
                            pBook.addOrigin(nBook.origin)
                            hasSame = true
                        }
                    }
                    if (!hasSame) {
                        containsData.add(nBook)
                    }
                } else if (!precision) {
                    var hasSame = false
                    otherData.forEach { pBook ->
                        coroutineContext.ensureActive()
                        if (pBook.name == nBook.name && pBook.author == nBook.author) {
                            pBook.addOrigin(nBook.origin)
                            hasSame = true
                        }
                    }
                    if (!hasSame) {
                        otherData.add(nBook)
                    }
                }
            }
            coroutineContext.ensureActive()
            equalData.sortByDescending { it.origins.size }
            equalData.addAll(containsData.sortedByDescending { it.origins.size })
            if (!precision) {
                equalData.addAll(otherData)
            }
            coroutineContext.ensureActive()
            searchBooks = equalData
        }
    }

    fun pause() {
        workingState.value = false
    }

    fun resume() {
        workingState.value = true
    }

    fun cancelSearch() {
        close()
        callBack.onSearchCancel()
    }

    fun close() {
        // 万象书屋: 关搜索时所有清理操作都吞异常.
        // 旧实现如果 ViewModelImpl 在 onCleared 链路上调到 close(), searchJob.cancel() / Executor.close()
        // 之间偶尔会传递 JobCancellationException, 被 ViewModelImpl.closeWithRuntimeException 打印到 stderr,
        // CrashHandler 可能把这条 noise 当真实 crash 上报到 /api/crash-log, 污染 crash 报表.
        runCatching { searchJob?.cancel() }
        runCatching { searchPool?.close() }
        searchPool = null
        mSearchId = 0L
    }

    interface CallBack {
        fun getSearchScope(): SearchScope
        fun onSearchStart()
        fun onSearchSuccess(searchBooks: List<SearchBook>)
        fun onSearchFinish(isEmpty: Boolean, hasMore: Boolean)
        fun onSearchCancel(exception: Throwable? = null)
    }

}