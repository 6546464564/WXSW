/**
 * 万象书屋 RN · 书籍详情
 * 1:1 对齐 iOS: BookDetailView.swift
 * - 封面 + 书名 + 作者 + kind tags + 最新章节 + 来源
 * - "加书架" / "已在书架" + "开始阅读" 双按钮
 * - 简介 Section (可展开)
 * - 目录 Section (换源按钮)
 */

import React, {useEffect, useState, useRef, useMemo} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  ActivityIndicator,
  StyleSheet,
  Alert,
  FlatList,
  Modal,
  Vibration,
} from 'react-native';
import {useRoute, useNavigation, RouteProp} from '@react-navigation/native';
import {NativeStackNavigationProp} from '@react-navigation/native-stack';
import BookCover from '../../components/BookCover';
import {ruleEngine} from '../../engine/RuleEngine';
import {changeSourceSearch, searchProxy, fetchProxyToc, ProxySearchBook, fetchProxyContent} from '../../api/search';
import {fetchLibraryChapters, searchLibrary} from '../../api/library';
import {getCachedToc, setCachedToc, getCachedContent, setCachedContent} from '../../utils/contentCache';
import {useSourceStore} from '../../store/sourceStore';
import {useBookshelfStore} from '../../store/bookshelfStore';
import {BookInfo, Chapter} from '../../engine/types';
import {Colors, Spacing, FontSize, Radius} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';
import {formatWordCount, cleanIntro} from '../../utils/bookFormat';
import {trackSource, getSortedOrigins} from '../../utils/sourceTracker';
import {bookDownloader, DownloadJob} from '../../utils/bookDownloader';

type DetailRoute = RouteProp<RootStackParamList, 'BookDetail'>;
type Nav = NativeStackNavigationProp<RootStackParamList>;

export default function BookDetailScreen() {
  const route = useRoute<DetailRoute>();
  const navigation = useNavigation<Nav>();
  const params = route.params;

  const bookUrl = params.bookUrl || '';
  const sourceUrl = params.sourceUrl || '';
  const isBookstoreMode = !bookUrl && !!params.bookName;

  const sources = useSourceStore(s => s.sources);
  const getEnabledSources = useSourceStore(s => s.getEnabledSources);
  const addBook = useBookshelfStore(s => s.addBook);
  const books = useBookshelfStore(s => s.books);

  const [info, setInfo] = useState<BookInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [introExpanded, setIntroExpanded] = useState(false);
  const [chapters, setChapters] = useState<Chapter[]>([]);
  const [tocLoading, setTocLoading] = useState(false);
  const [showToc, setShowToc] = useState(false);
  const [activeSourceUrl, setActiveSourceUrl] = useState(sourceUrl);
  const [resolvedBookUrl, setResolvedBookUrl] = useState(bookUrl);
  const bookstoreResolved = useRef(false);
  const [isResolvingSource, setIsResolvingSource] = useState(false);
  const [resolveFailed, setResolveFailed] = useState(false);
  const [resolvedSourceName, setResolvedSourceName] = useState('');
  const [showSourcePicker, setShowSourcePicker] = useState(false);
  const [sourceCandidates, setSourceCandidates] = useState<ProxySearchBook[]>([]);
  const [sourcePickerLoading, setSourcePickerLoading] = useState(false);
  const [downloadJob, setDownloadJob] = useState<DownloadJob | null>(null);

  const source = sources.find(s => s.bookSourceUrl === activeSourceUrl);
  const isOnShelf = books.some(
    b => b.bookUrl === resolvedBookUrl || (b.name === params.bookName && b.author === params.bookAuthor),
  );

  const cleaned = useMemo(() => cleanIntro(info?.intro), [info?.intro]);
  const displayedWordCount = useMemo(() => formatWordCount(info?.wordCount), [info?.wordCount]);
  const displayedUpdateTime = info?.updateTime || cleaned.updateTime;


  useEffect(() => {
    async function load() {
      if (isBookstoreMode) {
        if (bookstoreResolved.current) return;
        // 对齐 iOS: 先展示基本信息，后台异步找源
        setInfo({
          name: params.bookName || '',
          author: params.bookAuthor || '',
          coverUrl: params.bookCover,
          intro: params.bookIntro,
        });
        setLoading(false);
        setIsResolvingSource(true);
        setResolveFailed(false);

        let resolved = false;
        const resolveOk = (origin: string, url: string, srcName: string, isLibrary: boolean, extra?: Partial<BookInfo>) => {
          if (resolved && !isLibrary) return;
          resolved = true;
          bookstoreResolved.current = true;
          setActiveSourceUrl(origin);
          setResolvedBookUrl(url);
          setResolvedSourceName(srcName);
          if (extra) setInfo(prev => ({...prev!, ...extra}));
          setIsResolvingSource(false);
        };

        const bookName = params.bookName || '';
        const bookAuthor = params.bookAuthor || '';

        // Parallel: library + changeSource(limit=1) + proxySearch race; library always wins
        const libraryP = searchLibrary(bookName).then(libBooks => {
          const libMatch = libBooks.find(
            lb => lb.title === bookName ||
                  (lb.title.includes(bookName) && (!bookAuthor || lb.author === bookAuthor)),
          );
          if (libMatch) {
            resolveOk('wanxiang://library', `wanxiang://library/book/${libMatch.id}`, '书库', true, {
              name: libMatch.title, author: libMatch.author,
              coverUrl: libMatch.coverUrl, intro: libMatch.intro, kind: libMatch.category,
            });
          }
        }).catch(() => {});

        const changeSourceP = changeSourceSearch(bookName, bookAuthor, 1).then(candidates => {
          const match = candidates.find(c => c.name === bookName || c.name.includes(bookName));
          if (match?.bookUrl) {
            resolveOk(match.origin, match.bookUrl, match.originName || match.origin, false);
            trackSource(match.origin, true);
            const matchSource = getEnabledSources().find(s => s.bookSourceUrl === match.origin);
            if (matchSource) {
              ruleEngine.getBookInfo(matchSource, match.bookUrl).then(bookInfo => {
                setInfo(prev => ({
                  name: bookInfo.name || prev?.name || '', author: bookInfo.author || prev?.author || '',
                  coverUrl: bookInfo.coverUrl || prev?.coverUrl, intro: bookInfo.intro || prev?.intro,
                  kind: bookInfo.kind, lastChapter: bookInfo.lastChapter,
                  tocUrl: bookInfo.tocUrl, wordCount: bookInfo.wordCount,
                }));
              }).catch(() => {});
            }
          }
        }).catch(() => {});

        const proxyP = searchProxy(bookName).then(proxyBooks => {
          const proxyMatch = proxyBooks.find(b => b.name === bookName || b.name.includes(bookName));
          if (proxyMatch?.bookUrl) {
            trackSource(proxyMatch.origin, true);
            resolveOk(proxyMatch.origin, proxyMatch.bookUrl, proxyMatch.originName || proxyMatch.origin, false, {
              name: proxyMatch.name,
              author: (proxyMatch.author || '').replace(/^作者[：:]/, ''),
              coverUrl: proxyMatch.coverUrl, intro: proxyMatch.intro,
              kind: proxyMatch.kind, lastChapter: proxyMatch.lastChapter,
            });
          }
        }).catch(() => {});

        await Promise.all([libraryP, changeSourceP, proxyP]);

        if (!resolved) {
          setIsResolvingSource(false);
          setResolveFailed(true);
        }
        return;
      }

      if (isLibraryBook) {
        setInfo({
          name: params.bookName || '',
          author: params.bookAuthor || '',
          coverUrl: params.bookCover,
          intro: params.bookIntro,
          kind: '书库',
        });
        setLoading(false);
        return;
      }

      let resolvedSource = source;
      if (!resolvedSource && !activeSourceUrl) {
        const enabled = getEnabledSources();
        resolvedSource = enabled.length > 0 ? enabled[0] : undefined;
        if (resolvedSource) {
          setActiveSourceUrl(resolvedSource.bookSourceUrl);
          return;
        }
      }
      const paramsFallback: BookInfo = {
        name: params.bookName || '',
        author: params.bookAuthor || '',
        coverUrl: params.bookCover,
        intro: params.bookIntro,
      };

      if (resolvedSource) {
        try {
          const bookInfo = await ruleEngine.getBookInfo(resolvedSource, resolvedBookUrl);
          if (bookInfo?.name) {
            setInfo(bookInfo);
          } else {
            setInfo(paramsFallback);
          }
        } catch {
          setInfo(paramsFallback);
        }
      } else if (activeSourceUrl) {
        setInfo(paramsFallback);
      }
      setLoading(false);
    }
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source, resolvedBookUrl, activeSourceUrl]);

  useEffect(() => {
    if (!resolvedBookUrl) return;
    setDownloadJob(bookDownloader.getJob(resolvedBookUrl) || null);
    const unsub = bookDownloader.subscribe(job => {
      if (job.bookUrl === resolvedBookUrl) setDownloadJob({...job});
    });
    return unsub;
  }, [resolvedBookUrl]);

  const isLibraryBook = resolvedBookUrl.startsWith('wanxiang://library/book/');

  const loadToc = async () => {
    if (tocLoading || !resolvedBookUrl) {
      if (!resolvedBookUrl) {
        Alert.alert('提示', '正在搜索书源，请稍候再试');
      }
      return;
    }
    setTocLoading(true);
    try {
      if (isLibraryBook) {
        const bookId = parseInt(resolvedBookUrl.split('/').pop() || '0', 10);
        const libChapters = await fetchLibraryChapters(bookId);
        const toc: Chapter[] = libChapters
          .filter(ch => ch.status === 'done')
          .map(ch => ({
            title: ch.title,
            url: `wanxiang://library/book/${bookId}/chapter/${ch.idx}`,
            index: ch.idx,
          }));
        setChapters(toc);
        setShowToc(true);
      } else if (activeSourceUrl) {
        // 对齐 iOS: 优先读本地 AsyncStorage 缓存
        const cached = await getCachedToc<Chapter>(activeSourceUrl, resolvedBookUrl);
        if (cached && cached.length > 0) {
          setChapters(cached);
          setShowToc(true);
          setTocLoading(false);
          return;
        }
        let toc: Chapter[] = [];
        if (source) {
          try {
            const tocUrl = info?.tocUrl || resolvedBookUrl;
            toc = await ruleEngine.getToc(source, tocUrl);
          } catch {}
        }
        if (toc.length === 0) {
          const proxyChapters = await fetchProxyToc(activeSourceUrl, resolvedBookUrl);
          toc = proxyChapters.map((ch, i) => ({
            title: ch.title,
            url: ch.url,
            index: i,
          }));
        }
        // 对齐 iOS: TOC 变体兜底 — 主源失败时自动尝试其他可用源
        if (toc.length === 0 && info?.name) {
          try {
            const altCandidates = await changeSourceSearch(info.name, info.author || '', 5);
            for (const alt of altCandidates) {
              if (alt.origin === activeSourceUrl) continue;
              try {
                const altToc = await fetchProxyToc(alt.origin, alt.bookUrl);
                if (altToc.length > 0) {
                  toc = altToc.map((ch, i) => ({title: ch.title, url: ch.url, index: i}));
                  setActiveSourceUrl(alt.origin);
                  setResolvedBookUrl(alt.bookUrl);
                  setResolvedSourceName(alt.originName || alt.origin);
                  trackSource(alt.origin, true);
                  break;
                }
              } catch {}
            }
          } catch {}
        }
        if (toc.length > 0) {
          setChapters(toc);
          setShowToc(true);
          setCachedToc(activeSourceUrl, resolvedBookUrl, toc).catch(() => {});
          prefetchFirstChapter(toc);
        } else {
          Alert.alert('提示', '目录为空');
        }
      } else {
        Alert.alert('提示', '未找到可用书源');
      }
    } catch {
      Alert.alert('加载失败', '目录加载失败，请稍后重试');
    }
    setTocLoading(false);
  };

  const prefetchFirstChapter = (toc: Chapter[]) => {
    if (toc.length === 0 || !activeSourceUrl) return;
    const ch = toc[0];
    getCachedContent(activeSourceUrl, ch.url).then(hit => {
      if (hit) return;
      fetchProxyContent(activeSourceUrl, ch.url)
        .then(content => {
          if (content) setCachedContent(activeSourceUrl, ch.url, content).catch(() => {});
        })
        .catch(() => {});
    }).catch(() => {});
  };

  const handleChangeSource = async () => {
    if (!info?.name) {
      Alert.alert('提示', '书籍信息未加载');
      return;
    }
    setShowSourcePicker(true);
    setSourcePickerLoading(true);
    try {
      const candidates = await changeSourceSearch(info.name, info.author || '');
      const sortedOrigins = await getSortedOrigins(candidates.map(c => c.origin));
      const originRank = new Map(sortedOrigins.map((o, i) => [o, i]));
      candidates.sort((a, b) => (originRank.get(a.origin) ?? 999) - (originRank.get(b.origin) ?? 999));
      setSourceCandidates(candidates);
    } catch {
      Alert.alert('换源失败', '网络异常，请稍后重试');
      setShowSourcePicker(false);
    }
    setSourcePickerLoading(false);
  };

  const handlePickSource = (candidate: ProxySearchBook) => {
    setShowSourcePicker(false);
    setActiveSourceUrl(candidate.origin);
    setResolvedBookUrl(candidate.bookUrl);
    setLoading(true);
    setChapters([]);
  };

  const handleAddToShelf = () => {
    if (!info || !resolvedBookUrl) {
      Alert.alert('提示', '正在搜索书源，请稍候再试');
      return;
    }
    const doAdd = () => {
      addBook({
        name: info.name,
        author: info.author,
        coverUrl: info.coverUrl,
        bookUrl: resolvedBookUrl,
        sourceUrl: activeSourceUrl,
        lastChapterIndex: 0,
      });
      Vibration.vibrate(10);
    };
    const dup = books.find(
      b => b.bookUrl !== resolvedBookUrl && b.name === info.name && b.author === (info.author || ''),
    );
    if (dup) {
      Alert.alert(
        '此书已在书架',
        `《${dup.name}》来自其他源已在书架，是否再加一个？`,
        [
          {text: '取消', style: 'cancel'},
          {text: '仍然添加', onPress: doAdd},
        ],
      );
    } else {
      doAdd();
    }
  };

  const handleDownload = () => {
    if (!resolvedBookUrl || !activeSourceUrl || chapters.length === 0) {
      Alert.alert('提示', '请先加载目录');
      return;
    }
    bookDownloader.start(
      resolvedBookUrl,
      info?.name || params.bookName || '未知',
      activeSourceUrl,
      chapters.map(ch => ({url: ch.url, title: ch.title})),
    );
  };

  const handleRead = () => {
    if (!resolvedBookUrl) {
      Alert.alert('提示', '正在搜索书源，请稍候再试');
      return;
    }
    navigation.navigate('Reader', {
      bookUrl: resolvedBookUrl,
      chapterIndex: 0,
      sourceUrl: activeSourceUrl,
      bookName: info?.name || params.bookName,
      bookAuthor: info?.author || params.bookAuthor,
    });
  };

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color={Colors.primary} />
        <Text style={styles.loadingText}>加载中…</Text>
      </View>
    );
  }

  if (!info) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyIcon}>⚠</Text>
        <Text style={styles.emptyText}>无法加载书籍信息</Text>
        {!source && (
          <Text style={styles.emptyHint}>未找到可用书源</Text>
        )}
      </View>
    );
  }

  const kindTags = (info.kind || '')
    .split(/[,，、|｜/\n]/)
    .map(s => s.trim())
    .filter(s => s.length > 0);

  return (
    <View style={styles.container}>
    <ScrollView
      style={styles.flex}
      contentContainerStyle={styles.scrollContent}
      showsVerticalScrollIndicator={false}>
      {/* 头部卡片 — 对齐 iOS header area */}
      <View style={styles.headerCard}>
        <BookCover
          url={info.coverUrl}
          width={100}
          height={140}
          bookTitle={info.name}
          bookAuthor={info.author}
          borderRadius={6}
        />
        <View style={styles.meta}>
          <Text style={styles.title} numberOfLines={2}>
            {info.name}
          </Text>
          <Text style={styles.author}>{info.author || '未知作者'}</Text>

          {kindTags.length > 0 && (
            <ScrollView
              horizontal
              showsHorizontalScrollIndicator={false}
              style={styles.tagsScroll}
              contentContainerStyle={styles.tagsRow}>
              {kindTags.map(tag => (
                <View key={tag} style={styles.tag}>
                  <Text style={styles.tagText}>{tag}</Text>
                </View>
              ))}
            </ScrollView>
          )}

          {info.lastChapter ? (
            <Text style={styles.lastChapter} numberOfLines={1}>
              最新：{info.lastChapter}
            </Text>
          ) : null}

          {displayedWordCount ? (
            <Text style={styles.wordCount}>{displayedWordCount}</Text>
          ) : null}
          {displayedUpdateTime ? (
            <Text style={styles.updateTime}>更新：{displayedUpdateTime}</Text>
          ) : null}
        </View>
      </View>

      {/* 操作按钮 — 对齐 iOS actionButtons */}
      <View style={styles.actions}>
        <TouchableOpacity
          style={[styles.actionBtn, isOnShelf && styles.actionBtnDone]}
          onPress={handleAddToShelf}
          disabled={isOnShelf || isResolvingSource}
          activeOpacity={0.7}>
          <Text
            style={[
              styles.actionBtnText,
              isOnShelf && styles.actionBtnTextDone,
            ]}>
            {isOnShelf ? '✓ 已在书架' : '+ 加书架'}
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.actionBtn, styles.actionBtnPrimary, (isResolvingSource || resolveFailed) && {opacity: 0.5}]}
          onPress={handleRead}
          disabled={isResolvingSource || resolveFailed}
          activeOpacity={0.7}>
          {isResolvingSource ? (
            <View style={{flexDirection: 'row', alignItems: 'center', gap: 6}}>
              <ActivityIndicator size="small" color={Colors.white} />
              <Text style={styles.actionBtnTextPrimary}>查找书源中</Text>
            </View>
          ) : (
            <Text style={styles.actionBtnTextPrimary}>开始阅读</Text>
          )}
        </TouchableOpacity>
      </View>

      {/* 换源按钮 — 对齐 iOS sourceInfoText */}
      <TouchableOpacity
        style={styles.changeSourceBtn}
        activeOpacity={0.7}
        onPress={handleChangeSource}>
        <View style={{flexDirection: 'row', alignItems: 'center', gap: 6, flex: 1}}>
          <Text style={styles.changeSourceText} numberOfLines={1}>
            {isResolvingSource
              ? '来源：查找中…'
              : resolveFailed
                ? '暂未找到此书源，点此换源'
                : `换源 · ${isLibraryBook ? '书库' : (source?.bookSourceName || resolvedSourceName || '未知源')}`}
          </Text>
          {isResolvingSource && <ActivityIndicator size="small" color={Colors.primary} />}
        </View>
        <Text style={styles.changeSourceArrow}>›</Text>
      </TouchableOpacity>

      {/* 下载本书 — 对齐 iOS downloadRow */}
      {!isLibraryBook && (
        <View style={styles.downloadRow}>
          {downloadJob?.status === 'running' ? (
            <View style={styles.downloadRunning}>
              <View style={styles.downloadHeader}>
                <Text style={styles.downloadText}>
                  下载中 {downloadJob.completed + downloadJob.failed}/{downloadJob.total}
                </Text>
                <Text style={styles.downloadPercent}>
                  {downloadJob.total > 0 ? Math.round(((downloadJob.completed + downloadJob.failed) / downloadJob.total) * 100) : 0}%
                </Text>
              </View>
              <View style={styles.progressBar}>
                <View
                  style={[
                    styles.progressFill,
                    {width: `${downloadJob.total > 0 ? ((downloadJob.completed + downloadJob.failed) / downloadJob.total) * 100 : 0}%`},
                  ]}
                />
              </View>
              <TouchableOpacity onPress={() => bookDownloader.cancel(resolvedBookUrl)} style={styles.downloadCancelBtn}>
                <Text style={styles.downloadCancelText}>取消</Text>
              </TouchableOpacity>
            </View>
          ) : downloadJob?.status === 'finished' ? (
            <View style={styles.downloadFinished}>
              <Text style={styles.downloadDoneText}>
                已下载 {downloadJob.completed}/{downloadJob.total} 章
                {downloadJob.failed > 0 ? ` (${downloadJob.failed} 章失败)` : ''}
              </Text>
              <TouchableOpacity onPress={handleDownload}>
                <Text style={styles.downloadRetryText}>重新下载</Text>
              </TouchableOpacity>
            </View>
          ) : downloadJob?.status === 'error' ? (
            <View style={styles.downloadFinished}>
              <Text style={styles.downloadErrorText}>下载失败</Text>
              <TouchableOpacity onPress={handleDownload}>
                <Text style={styles.downloadRetryText}>重试</Text>
              </TouchableOpacity>
            </View>
          ) : (
            <TouchableOpacity
              style={[styles.downloadBtn, chapters.length === 0 && {opacity: 0.5}]}
              disabled={chapters.length === 0}
              onPress={handleDownload}
              activeOpacity={0.7}>
              <Text style={styles.downloadBtnText}>
                {chapters.length > 0 ? `下载本书 (${chapters.length} 章)` : '加载目录后可下载'}
              </Text>
            </TouchableOpacity>
          )}
        </View>
      )}

      {/* 简介 — 对齐 iOS introSection + cleanedIntro */}
      {cleaned.text ? (
        <View style={styles.introSection}>
          <Text style={styles.sectionTitle}>简介</Text>
          <Text
            style={styles.introText}
            numberOfLines={introExpanded ? undefined : 4}>
            {cleaned.text}
          </Text>
          <TouchableOpacity
            style={styles.expandBtn}
            onPress={() => setIntroExpanded(!introExpanded)}>
            <Text style={styles.expandText}>
              {introExpanded ? '收起' : '展开'}
            </Text>
          </TouchableOpacity>
        </View>
      ) : null}

      {/* 目录入口 */}
      <TouchableOpacity
        style={styles.tocEntry}
        activeOpacity={0.7}
        onPress={loadToc}>
        <Text style={styles.sectionTitle}>目录</Text>
        <View style={styles.tocRight}>
          {tocLoading ? (
            <ActivityIndicator size="small" color={Colors.primary} />
          ) : info.lastChapter ? (
            <Text style={styles.tocLastChapter} numberOfLines={1}>
              {info.lastChapter}
            </Text>
          ) : null}
          <Text style={styles.tocArrow}>›</Text>
        </View>
      </TouchableOpacity>

    </ScrollView>

      {/* 目录弹窗 — 使用 Modal 确保全屏覆盖 */}
      <Modal
        visible={showToc && chapters.length > 0}
        transparent
        animationType="slide"
        onRequestClose={() => setShowToc(false)}>
        <View style={styles.tocOverlay}>
          <TouchableOpacity
            style={styles.tocBackdrop}
            activeOpacity={1}
            onPress={() => setShowToc(false)}
          />
          <View style={styles.tocPanel}>
            <View style={styles.tocPanelHeader}>
              <Text style={styles.tocPanelTitle}>
                目录 ({chapters.length}章)
              </Text>
              <TouchableOpacity onPress={() => setShowToc(false)}>
                <Text style={styles.tocCloseBtn}>✕</Text>
              </TouchableOpacity>
            </View>
            <FlatList
              data={chapters}
              keyExtractor={item => String(item.index)}
              renderItem={({item}) => (
                <TouchableOpacity
                  style={styles.tocRow}
                  onPress={() => {
                    setShowToc(false);
                    navigation.navigate('Reader', {
                      bookUrl: resolvedBookUrl,
                      chapterIndex: item.index,
                      sourceUrl: activeSourceUrl,
                      bookName: info?.name || params.bookName,
                      bookAuthor: info?.author || params.bookAuthor,
                    });
                  }}>
                  <Text style={styles.tocRowText} numberOfLines={1}>
                    {item.title}
                  </Text>
                </TouchableOpacity>
              )}
            />
          </View>
        </View>
      </Modal>

      {/* 换源选择器 Modal */}
      <Modal
        visible={showSourcePicker}
        transparent
        animationType="slide"
        onRequestClose={() => setShowSourcePicker(false)}>
        <View style={styles.tocOverlay}>
          <TouchableOpacity
            style={styles.tocBackdrop}
            activeOpacity={1}
            onPress={() => setShowSourcePicker(false)}
          />
          <View style={styles.tocPanel}>
            <View style={styles.tocPanelHeader}>
              <Text style={styles.tocPanelTitle}>选择书源</Text>
              <TouchableOpacity onPress={() => setShowSourcePicker(false)}>
                <Text style={styles.tocCloseBtn}>✕</Text>
              </TouchableOpacity>
            </View>
            {sourcePickerLoading ? (
              <View style={styles.sourcePickerLoading}>
                <ActivityIndicator size="small" color={Colors.primary} />
                <Text style={styles.sourcePickerLoadingText}>搜索书源中…</Text>
              </View>
            ) : sourceCandidates.length === 0 ? (
              <View style={styles.sourcePickerLoading}>
                <Text style={styles.sourcePickerLoadingText}>未找到其他书源</Text>
              </View>
            ) : (
              <FlatList
                data={sourceCandidates}
                keyExtractor={item => item.origin + item.bookUrl}
                renderItem={({item}) => {
                  const isCurrent = item.origin === activeSourceUrl;
                  return (
                    <TouchableOpacity
                      style={[styles.sourceRow, isCurrent && styles.sourceRowActive]}
                      activeOpacity={0.6}
                      onPress={() => !isCurrent && handlePickSource(item)}>
                      <View style={styles.sourceRowLeft}>
                        <Text style={[styles.sourceRowName, isCurrent && styles.sourceRowNameActive]} numberOfLines={1}>
                          {item.originName || item.origin}
                        </Text>
                        {item.lastChapter ? (
                          <Text style={styles.sourceRowChapter} numberOfLines={1}>
                            最新：{item.lastChapter}
                          </Text>
                        ) : null}
                      </View>
                      {isCurrent && <Text style={styles.sourceRowCheck}>✓</Text>}
                    </TouchableOpacity>
                  );
                }}
              />
            )}
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: Colors.background},
  flex: {flex: 1},
  scrollContent: {paddingBottom: 40},
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: Colors.background,
    gap: 12,
  },
  loadingText: {fontSize: 12, color: Colors.textSecondary},
  emptyIcon: {fontSize: 48, opacity: 0.6},
  emptyText: {fontSize: FontSize.md, color: Colors.textSecondary},
  emptyHint: {fontSize: 12, color: Colors.textSecondary, opacity: 0.7},

  // Header
  headerCard: {
    flexDirection: 'row',
    padding: Spacing.md,
    marginHorizontal: Spacing.md,
    marginTop: Spacing.md,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
    gap: Spacing.md,
  },
  meta: {flex: 1, justifyContent: 'center', gap: 4},
  title: {
    fontSize: FontSize.xl,
    fontWeight: 'bold',
    color: Colors.textPrimary,
  },
  author: {fontSize: FontSize.md, color: Colors.textSecondary},
  tagsScroll: {marginTop: 4},
  tagsRow: {gap: 6},
  tag: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 999,
    backgroundColor: `${Colors.divider}80`,
  },
  tagText: {fontSize: 10, color: Colors.textSecondary},
  lastChapter: {fontSize: 12, color: Colors.textSecondary, marginTop: 2},
  wordCount: {fontSize: 11, color: Colors.primary, marginTop: 2},
  updateTime: {fontSize: 11, color: Colors.textSecondary, marginTop: 2},

  // Actions
  actions: {
    flexDirection: 'row',
    paddingHorizontal: Spacing.md,
    marginTop: Spacing.lg,
    gap: Spacing.md,
  },
  actionBtn: {
    flex: 1,
    paddingVertical: 12,
    borderRadius: Radius.md,
    borderWidth: 1.5,
    borderColor: Colors.primary,
    alignItems: 'center',
  },
  actionBtnDone: {borderColor: Colors.divider, opacity: 0.6},
  actionBtnText: {
    fontSize: FontSize.md,
    color: Colors.primary,
    fontWeight: '600',
  },
  actionBtnTextDone: {color: Colors.textSecondary},
  actionBtnPrimary: {backgroundColor: Colors.primary, borderColor: Colors.primary},
  actionBtnTextPrimary: {fontSize: FontSize.md, color: Colors.white, fontWeight: '600'},

  // Change source
  changeSourceBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginHorizontal: Spacing.md,
    marginTop: Spacing.md,
    paddingHorizontal: Spacing.md,
    paddingVertical: 12,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
  },
  changeSourceText: {fontSize: FontSize.md, color: Colors.textPrimary},
  changeSourceArrow: {fontSize: 20, color: Colors.textSecondary},

  // Download
  downloadRow: {
    marginHorizontal: Spacing.md,
    marginTop: Spacing.md,
  },
  downloadBtn: {
    paddingVertical: 12,
    paddingHorizontal: Spacing.md,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
    alignItems: 'center' as const,
  },
  downloadBtnText: {fontSize: FontSize.md, color: Colors.primary, fontWeight: '600' as const},
  downloadRunning: {
    padding: 12,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
    gap: 6,
  },
  downloadHeader: {flexDirection: 'row' as const, justifyContent: 'space-between' as const},
  downloadText: {fontSize: 13, color: Colors.textPrimary, fontWeight: '500' as const},
  downloadPercent: {fontSize: 12, color: Colors.textSecondary},
  progressBar: {height: 4, backgroundColor: Colors.divider, borderRadius: 2, overflow: 'hidden' as const},
  progressFill: {height: 4, backgroundColor: Colors.primary, borderRadius: 2},
  downloadCancelBtn: {alignSelf: 'flex-end' as const, paddingTop: 4},
  downloadCancelText: {fontSize: 12, color: '#e67e22', fontWeight: '500' as const},
  downloadFinished: {
    flexDirection: 'row' as const,
    justifyContent: 'space-between' as const,
    alignItems: 'center' as const,
    padding: 12,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
  },
  downloadDoneText: {fontSize: 13, color: Colors.textPrimary},
  downloadErrorText: {fontSize: 13, color: '#e67e22'},
  downloadRetryText: {fontSize: 13, color: Colors.primary, fontWeight: '600' as const},

  // Intro
  introSection: {
    padding: Spacing.md,
    marginTop: Spacing.md,
    marginHorizontal: Spacing.md,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
  },
  sectionTitle: {
    fontSize: FontSize.lg,
    fontWeight: '600',
    color: Colors.textPrimary,
    marginBottom: 8,
  },
  introText: {
    fontSize: FontSize.md,
    color: Colors.textSecondary,
    lineHeight: 24,
  },
  expandBtn: {alignItems: 'center', paddingTop: 8},
  expandText: {fontSize: 12, color: Colors.primary, fontWeight: '500'},

  // TOC entry
  tocEntry: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginHorizontal: Spacing.md,
    marginTop: Spacing.md,
    paddingHorizontal: Spacing.md,
    paddingVertical: 14,
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
  },
  tocRight: {flexDirection: 'row', alignItems: 'center', gap: 8, flex: 1, justifyContent: 'flex-end'},
  tocLastChapter: {fontSize: 12, color: Colors.textSecondary, flex: 1, textAlign: 'right'},
  tocArrow: {fontSize: 20, color: Colors.textSecondary},

  // TOC overlay
  tocOverlay: {
    flex: 1,
    justifyContent: 'flex-end',
  },
  tocBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  tocPanel: {
    maxHeight: '60%',
    backgroundColor: Colors.card,
    borderTopLeftRadius: Radius.lg,
    borderTopRightRadius: Radius.lg,
  },
  tocPanelHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.divider,
  },
  tocPanelTitle: {fontSize: FontSize.md, fontWeight: '600', color: Colors.textPrimary},
  tocCloseBtn: {fontSize: 18, color: Colors.textSecondary, padding: 4},
  tocRow: {
    paddingHorizontal: Spacing.md,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.divider,
  },
  tocRowText: {fontSize: 13, color: Colors.textPrimary},

  // Source picker
  sourcePickerLoading: {
    paddingVertical: 40,
    alignItems: 'center',
    gap: 10,
  },
  sourcePickerLoadingText: {fontSize: 13, color: Colors.textSecondary},
  sourceRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.md,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.divider,
  },
  sourceRowActive: {backgroundColor: `${Colors.primary}10`},
  sourceRowLeft: {flex: 1, gap: 3},
  sourceRowName: {fontSize: FontSize.md, color: Colors.textPrimary, fontWeight: '500'},
  sourceRowNameActive: {color: Colors.primary},
  sourceRowChapter: {fontSize: 12, color: Colors.textSecondary},
  sourceRowCheck: {fontSize: 16, color: Colors.primary, fontWeight: '600', marginLeft: 8},
});
