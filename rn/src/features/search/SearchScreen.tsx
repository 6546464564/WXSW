/**
 * 万象书屋 RN · 搜索
 * 1:1 对齐 iOS: SearchView.swift
 * - 搜索栏 (圆角输入框 + 清除按钮)
 * - 防抖 300ms
 * - 搜索中状态 (ActivityIndicator + "N 个书源搜索中…")
 * - 搜索历史 (clock icon + 清除按钮)
 * - 结果列表 (封面 + 书名 + 源数 badge + 作者 + kind tags + 最新章节 + 简介)
 * - 二次过滤 chips (全部/多源/百万字+/近期更新)
 * - 空态
 */

import React, {useState, useCallback, useRef, useEffect} from 'react';
import {
  View,
  Text,
  TextInput,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
  StyleSheet,
  SafeAreaView,
} from 'react-native';
import {useNavigation, useRoute, RouteProp} from '@react-navigation/native';
import {NativeStackNavigationProp} from '@react-navigation/native-stack';
import Ionicons from 'react-native-vector-icons/Ionicons';
import BookCover from '../../components/BookCover';
import {searchProxy, type ProxySearchBook, changeSourceSearch} from '../../api/search';
import {searchLibrary} from '../../api/library';
import {SearchResult} from '../../engine/types';
import {useThemeColors, Spacing, FontSize} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';
import {getObject, setObject} from '../../utils/storage';
import {formatWordCount} from '../../utils/bookFormat';

type Nav = NativeStackNavigationProp<RootStackParamList>;
type Route = RouteProp<RootStackParamList, 'Search'>;

type Filter = 'all' | 'multiSource' | 'longBook' | 'recentUpdate';
const FILTER_LABELS: {key: Filter; label: string}[] = [
  {key: 'all', label: '全部'},
  {key: 'multiSource', label: '多源 (≥2)'},
  {key: 'longBook', label: '百万字+'},
  {key: 'recentUpdate', label: '近期更新'},
];

const MAX_HISTORY = 20;
const HISTORY_KEY = 'wanxiang.search.history';

// 万象书屋 (lint fix): relevanceTier/sortResults 是纯函数, 不依赖组件状态,
// 提到模块级避免 useCallback 的 exhaustive-deps 告警 (每次渲染新引用).
function relevanceTier(item: SearchResult, kw: string): number {
  const name = (item.name || '').toLowerCase().replace(/\s+/g, '');
  const author = (item.author || '').toLowerCase().replace(/^作者[：:]/, '').replace(/\s+/g, '');
  if (name === kw) return 0;
  if (author === kw) return 1;
  if (name.startsWith(kw)) return 2;
  if (name.includes(kw)) return 3;
  if (author.includes(kw)) return 4;
  return 5;
}

function sortResults(items: SearchResult[], keyword: string): SearchResult[] {
  const kw = keyword.toLowerCase().replace(/\s+/g, '');
  return items.sort((a, b) => {
    const ta = relevanceTier(a, kw);
    const tb = relevanceTier(b, kw);
    if (ta !== tb) return ta - tb;
    // 同层：源数多的排前面
    if (a.distinctOriginCount !== b.distinctOriginCount) {
      return b.distinctOriginCount - a.distinctOriginCount;
    }
    // 书库有章节数据的优先
    const libA = a.sourceUrl === 'wanxiang://library' ? 1 : 0;
    const libB = b.sourceUrl === 'wanxiang://library' ? 1 : 0;
    return libB - libA;
  });
}

export default function SearchScreen() {
  const route = useRoute<Route>();
  const navigation = useNavigation<Nav>();
  const colors = useThemeColors();
  const [keyword, setKeyword] = useState(route.params?.keyword || '');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [history, setHistory] = useState<string[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [errorMsg, setErrorMsg] = useState('');
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inputRef = useRef<TextInput>(null);

  useEffect(() => {
    inputRef.current?.focus();
    getObject<string[]>(HISTORY_KEY).then(saved => {
      if (saved && saved.length > 0) setHistory(saved);
    }).catch(() => {});
  }, []);

  const addHistory = (kw: string) => {
    setHistory(prev => {
      const next = [kw, ...prev.filter(h => h !== kw)].slice(0, MAX_HISTORY);
      setObject(HISTORY_KEY, next).catch(() => {});
      return next;
    });
  };

  function proxyBookToSearchResult(b: ProxySearchBook): SearchResult {
    return {
      name: b.name,
      author: b.author,
      intro: b.intro,
      kind: b.kind,
      coverUrl: b.coverUrl,
      bookUrl: b.bookUrl,
      lastChapter: b.lastChapter,
      sourceUrl: b.origin,
      sourceName: b.originName,
      distinctOriginCount: 1 + (b.mergedSourceURLs?.length || 0),
      mergedSourceURLs: b.mergedSourceURLs || [],
      mergedSourceNames: b.mergedSourceNames || [],
    };
  }

  const doSearch = useCallback(
    async (kw?: string) => {
      const searchKw = (kw || keyword).trim();
      if (!searchKw) return;
      addHistory(searchKw);
      setSearching(true);
      setResults([]);
      setErrorMsg('');
      setFilter('all');

      const allResults: SearchResult[] = [];
      const dedupeMap = new Map<string, number>();

      // 1. 搜索后端书库
      try {
        const libBooks = await searchLibrary(searchKw);
        for (const lb of libBooks) {
          const item: SearchResult = {
            name: lb.title,
            author: lb.author,
            intro: lb.intro,
            kind: lb.category,
            coverUrl: lb.coverUrl,
            bookUrl: `wanxiang://library/book/${lb.id}`,
            wordCount: lb.totalChapters > 0 ? `${lb.totalChapters}章` : undefined,
            sourceUrl: 'wanxiang://library',
            sourceName: '书库',
            distinctOriginCount: 1,
            mergedSourceURLs: [],
            mergedSourceNames: [],
          };
          const dk = `${item.name}::${item.author}`.toLowerCase().replace(/\s+/g, '');
          dedupeMap.set(dk, allResults.length);
          allResults.push(item);
        }
        if (allResults.length > 0) {
          setResults(sortResults([...allResults], searchKw));
        }
      } catch {}

      // 2. 服务端代搜
      try {
        const proxyBooks = await searchProxy(searchKw);
        for (const pb of proxyBooks) {
          const item = proxyBookToSearchResult(pb);
          const dk = `${item.name}::${item.author}`.toLowerCase().replace(/\s+/g, '');
          const existIdx = dedupeMap.get(dk);
          if (existIdx !== undefined && existIdx < allResults.length) {
            const row = allResults[existIdx];
            if (!row.mergedSourceURLs.includes(item.sourceUrl)) {
              row.mergedSourceURLs.push(item.sourceUrl);
              row.mergedSourceNames.push(item.sourceName);
              row.distinctOriginCount = 1 + row.mergedSourceURLs.length;
            }
            if (!row.intro && item.intro) row.intro = item.intro;
            if (!row.coverUrl && item.coverUrl) row.coverUrl = item.coverUrl;
          } else {
            dedupeMap.set(dk, allResults.length);
            allResults.push(item);
          }
        }
        setResults(sortResults([...allResults], searchKw));
      } catch (e: any) {
        const msg = e?.message || String(e);
        console.warn('[Search] 服务端搜索失败:', msg);
        setErrorMsg(msg);
      }
      setSearching(false);

      // 对齐 iOS: 异步补全缺封面/字数的结果
      enrichMissing(allResults);
    },
    [keyword],
  );

  const enrichMissing = async (items: SearchResult[]) => {
    const needEnrich = items.filter(
      (r, i) => i < 15 && (!r.coverUrl || !r.wordCount),
    );
    for (const item of needEnrich) {
      try {
        const candidates = await changeSourceSearch(item.name, item.author || '', 1);
        const match = candidates.find(c => c.name === item.name);
        if (!match) continue;
        let changed = false;
        if (!item.coverUrl && match.coverUrl) { item.coverUrl = match.coverUrl; changed = true; }
        if (!item.wordCount && match.wordCount) { item.wordCount = formatWordCount(match.wordCount); changed = true; }
        if (!item.lastChapter && match.lastChapter) { item.lastChapter = match.lastChapter; changed = true; }
        if (!item.intro && match.intro) { item.intro = match.intro; changed = true; }
        if (changed) setResults(prev => [...prev]);
      } catch {}
    }
  };

  const onChangeText = (text: string) => {
    setKeyword(text);
    if (!text.trim()) {
      setResults([]);
      return;
    }
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      if (text.trim().length >= 2) doSearch(text);
    }, 300);
  };

  const clearKeyword = () => {
    setKeyword('');
    setResults([]);
    setFilter('all');
  };

  const displayResults = (() => {
    switch (filter) {
      case 'multiSource':
        return results.filter(r => r.distinctOriginCount >= 2);
      case 'longBook': {
        const parseWords = (s?: string) => {
          if (!s) return 0;
          const t = s.replace(/\s/g, '').replace(/字/g, '');
          if (t.includes('万')) {
            const n = parseFloat(t.replace('万', ''));
            return isNaN(n) ? 0 : n * 10000;
          }
          const n = parseInt(t.replace(/,/g, ''), 10);
          return isNaN(n) ? 0 : n;
        };
        return results.filter(r => parseWords(r.wordCount) >= 1_000_000);
      }
      case 'recentUpdate': {
        return results.filter(r => !!r.updateTime);
      }
      default:
        return results;
    }
  })();

  const showHistory = keyword.trim() === '' && !searching;
  const showEmpty = !searching && keyword.trim() !== '' && results.length === 0;

  return (
    <SafeAreaView style={[styles.container, {backgroundColor: colors.background}]}>
      {/* 搜索栏 — 对齐 iOS searchBar */}
      <View style={[styles.searchBar, {backgroundColor: colors.card}]}>
        <Ionicons name="search" size={16} color={colors.textSecondary} />
        <TextInput
          ref={inputRef}
          style={[styles.searchInput, {color: colors.textPrimary}]}
          placeholder="书名 / 作者"
          placeholderTextColor={colors.textSecondary}
          value={keyword}
          onChangeText={onChangeText}
          onSubmitEditing={() => doSearch()}
          returnKeyType="search"
        />
        {keyword.length > 0 && (
          <TouchableOpacity onPress={clearKeyword} style={{padding: 4}}>
            <Ionicons name="close-circle" size={16} color={colors.textSecondary} />
          </TouchableOpacity>
        )}
      </View>

      {/* 搜索中 */}
      {searching && results.length === 0 && (
        <View style={styles.loadingWrap}>
          <ActivityIndicator size="large" color={colors.primary} />
          <Text style={[styles.loadingText, {color: colors.textSecondary}]}>搜索中…</Text>
        </View>
      )}

      {/* 空态 */}
      {showEmpty && (
        <View style={styles.emptyWrap}>
          <Text style={styles.emptyIcon}>🔍</Text>
          <Text style={[styles.emptyText, {color: colors.textSecondary}]}>没有搜到「{keyword}」</Text>
          {errorMsg ? (
            <Text style={styles.errorText}>{errorMsg}</Text>
          ) : null}
        </View>
      )}

      {/* 历史 */}
      {showHistory && (
        <View style={styles.historyWrap}>
          {history.length === 0 ? (
            <View style={styles.emptyWrap}>
              <Text style={styles.emptyIcon}>⌕</Text>
              <Text style={[styles.emptyText, {color: colors.textSecondary}]}>输入关键词搜索</Text>
            </View>
          ) : (
            <>
              <View style={styles.historyHeader}>
                <Text style={[styles.historyTitle, {color: colors.textSecondary}]}>搜索历史</Text>
                <TouchableOpacity onPress={() => { setHistory([]); setObject(HISTORY_KEY, []).catch(() => {}); }}>
                  <Text style={[styles.historyClear, {color: colors.primary}]}>清除</Text>
                </TouchableOpacity>
              </View>
              {history.map(h => (
                <TouchableOpacity
                  key={h}
                  style={styles.historyRow}
                  onPress={() => {
                    setKeyword(h);
                    doSearch(h);
                  }}>
                  <Text style={styles.historyIcon}>🕐</Text>
                  <Text style={[styles.historyText, {color: colors.textPrimary}]}>{h}</Text>
                </TouchableOpacity>
              ))}
            </>
          )}
        </View>
      )}

      {/* 过滤 chips + 结果列表 */}
      {results.length > 0 && (
        <View style={{flex: 1}}>
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={{flexShrink: 0, flexGrow: 0}}
            contentContainerStyle={styles.filterBar}>
            {FILTER_LABELS.map(f => {
              const selected = filter === f.key;
              return (
                <TouchableOpacity
                  key={f.key}
                  style={[
                    styles.filterChip,
                    {backgroundColor: `${colors.divider}80`},
                    selected && {backgroundColor: `${colors.primary}2E`},
                  ]}
                  onPress={() => setFilter(f.key)}>
                  <Text
                    style={[
                      styles.filterText,
                      {color: colors.textSecondary},
                      selected && {color: colors.primary, fontWeight: '600'},
                    ]}>
                    {f.label}
                  </Text>
                </TouchableOpacity>
              );
            })}
          </ScrollView>

          {/* 结果数 + 搜索中提示 */}
          <View style={styles.resultHeader}>
            <Text style={[styles.resultCount, {color: colors.textSecondary}]}>{results.length} 条结果</Text>
            {searching && (
              <View style={styles.resultSearching}>
                <ActivityIndicator size="small" color={colors.primary} />
                <Text style={[styles.resultSearchingText, {color: colors.textSecondary}]}>搜索中</Text>
              </View>
            )}
          </View>

          <FlatList
            style={{flex: 1}}
            data={displayResults}
            keyExtractor={(item, idx) =>
              `${item.sourceUrl}-${item.bookUrl}-${idx}`
            }
            contentContainerStyle={styles.listContent}
            renderItem={({item}) => {
              const kindTags = (item.kind || '')
                .split(/[,，、|｜/\n]/)
                .map(s => s.trim())
                .filter(s => s.length > 0);
              if (item.wordCount) {
                const wc = item.wordCount.trim();
                if (wc && !kindTags.includes(wc)) kindTags.unshift(wc);
              }
              return (
                <TouchableOpacity
                  style={styles.resultRow}
                  activeOpacity={0.7}
                  onPress={() =>
                    navigation.navigate('BookDetail', {
                      bookUrl: item.bookUrl,
                      sourceUrl: item.sourceUrl,
                      bookName: item.name,
                      bookAuthor: item.author,
                      bookCover: item.coverUrl,
                      bookIntro: item.intro,
                    })
                  }>
                  <BookCover
                    url={item.coverUrl}
                    width={56}
                    height={78}
                    bookTitle={item.name}
                    bookAuthor={item.author}
                    borderRadius={4}
                  />
                  <View style={styles.resultInfo}>
                    <View style={styles.resultTitleRow}>
                      <Text style={[styles.resultTitle, {color: colors.textPrimary}]} numberOfLines={1}>
                        {item.name}
                      </Text>
                      <View style={[styles.sourceBadge, {backgroundColor: `${colors.primary}D1`}]}>
                        <Text style={styles.sourceBadgeText}>
                          {item.distinctOriginCount}
                        </Text>
                      </View>
                    </View>
                    <Text style={[styles.resultAuthor, {color: colors.textSecondary}]} numberOfLines={1}>
                      作者：{item.author || '未知'}
                    </Text>
                    {kindTags.length > 0 && (
                      <ScrollView
                        horizontal
                        showsHorizontalScrollIndicator={false}
                        style={styles.kindTagsRow}>
                        {kindTags.slice(0, 5).map(tag => (
                          <View key={tag} style={[styles.kindTag, {backgroundColor: `${colors.divider}8C`}]}>
                            <Text style={[styles.kindTagText, {color: colors.textSecondary}]}>{tag}</Text>
                          </View>
                        ))}
                      </ScrollView>
                    )}
                    {item.lastChapter ? (
                      <Text style={[styles.resultLastChapter, {color: colors.textSecondary}]} numberOfLines={1}>
                        最新：{item.lastChapter}
                      </Text>
                    ) : null}
                    {item.intro ? (
                      <Text style={[styles.resultIntro, {color: `${colors.textSecondary}EB`}]} numberOfLines={2}>
                        {item.intro}
                      </Text>
                    ) : null}
                  </View>
                </TouchableOpacity>
              );
            }}
          />
        </View>
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1},

  searchBar: {
    flexDirection: 'row',
    alignItems: 'center',
    marginHorizontal: 12,
    marginVertical: 8,
    paddingHorizontal: 10,
    height: 40,
    borderRadius: 10,
    gap: 8,
  },
  searchInput: {
    flex: 1,
    fontSize: FontSize.md,
    padding: 0,
  },

  loadingWrap: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 12,
  },
  loadingText: {fontSize: 12},

  emptyWrap: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 12,
  },
  emptyIcon: {fontSize: 48, opacity: 0.6},
  emptyText: {fontSize: FontSize.md - 1},
  errorText: {fontSize: 12, color: '#F59E0B'},

  historyWrap: {flex: 1},
  historyHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingVertical: 8,
  },
  historyTitle: {fontSize: 12},
  historyClear: {fontSize: 12},
  historyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingVertical: 12,
    gap: 10,
  },
  historyIcon: {fontSize: 14},
  historyText: {fontSize: FontSize.md},

  filterBar: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    gap: 8,
  },
  filterChip: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 999,
  },
  filterText: {fontSize: 12},

  resultHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 6,
    gap: 8,
    flexShrink: 0,
  },
  resultCount: {fontSize: 12},
  resultSearching: {flexDirection: 'row', alignItems: 'center', gap: 4},
  resultSearchingText: {fontSize: 12},
  listContent: {paddingBottom: 40},
  resultRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingHorizontal: Spacing.md,
    paddingVertical: 10,
    gap: 12,
  },
  resultInfo: {flex: 1, gap: 5},
  resultTitleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  resultTitle: {
    flex: 1,
    fontSize: FontSize.md,
    fontWeight: '600',
  },
  sourceBadge: {
    minWidth: 18,
    height: 18,
    borderRadius: 9,
    paddingHorizontal: 5,
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: 8,
  },
  sourceBadgeText: {fontSize: 10, fontWeight: '600', color: '#fff'},
  resultAuthor: {fontSize: 12},
  kindTagsRow: {marginTop: 4, flexDirection: 'row'},
  kindTag: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 999,
    marginRight: 6,
  },
  kindTagText: {fontSize: 10},
  resultLastChapter: {fontSize: 12, marginTop: 2},
  resultIntro: {
    fontSize: 12,
    lineHeight: 18,
    marginTop: 2,
  },
});
