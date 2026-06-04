/**
 * 万象书屋 RN · 书城
 * 1:1 对齐 iOS: BookStoreView.swift + BookStoreViewModel
 *
 * 数据流: fetchBookStoreData(channel) → mirror JSON → 按频道取 ranks → 3 sections
 * - Hero: fyRank[0]
 * - 阅读榜 (hotRank): 8 books, swap pagination
 * - 新书榜 (newbRank): 8 books, swap pagination
 * - 推荐榜 (recRank): 8 books with rank badges, swap pagination
 */

import React, {useEffect, useState, useCallback, useRef, useMemo} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  SafeAreaView,
  RefreshControl,
  useWindowDimensions,
} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {NativeStackNavigationProp} from '@react-navigation/native-stack';
import LinearGradient from 'react-native-linear-gradient';
import Ionicons from 'react-native-vector-icons/Ionicons';
import BookCover from '../../components/BookCover';
import {
  fetchBookStoreData,
  clearMirrorCache,
  QidianBook,
  RankingGroup,
  Channel,
} from '../../api/bookstore';
import {useThemeColors, type ThemeColors, Spacing, FontSize, Radius} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';
import {useBookshelfStore} from '../../store/bookshelfStore';

type Nav = NativeStackNavigationProp<RootStackParamList>;

const SECTION_PAD = 14;
const GRID_COLS = 4;
const GRID_GAP = 10;
const SECTION_INNER_PAD = 12;

const CHANNEL_LABELS: Record<Channel, string> = {
  male: '男生',
  female: '女生',
  publish: '出版',
};

export default function BookStoreScreen() {
  const colors = useThemeColors();
  const {width: screenW} = useWindowDimensions();
  const cellW = useMemo(
    () => (screenW - SECTION_PAD * 2 - SECTION_INNER_PAD * 2 - GRID_GAP * (GRID_COLS - 1)) / GRID_COLS,
    [screenW],
  );
  const cellCoverH = (cellW * 4) / 3;
  const [rankings, setRankings] = useState<RankingGroup[]>([]);
  const [heroBook, setHeroBook] = useState<QidianBook | null>(null);
  const [allBooks, setAllBooks] = useState<QidianBook[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [failed, setFailed] = useState(false);
  const [channel, setChannel] = useState<Channel>('male');
  const [swapPages, setSwapPages] = useState<number[]>([0, 0, 0]);
  const navigation = useNavigation<Nav>();
  const loadedChannels = useRef<Set<Channel>>(new Set());
  const shelfBooks = useBookshelfStore(s => s.books);
  const shelfKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const b of shelfBooks) {
      keys.add(`${b.name}@@${b.author}`);
    }
    return keys;
  }, [shelfBooks]);
  const isOnShelf = (book: QidianBook) => shelfKeys.has(`${book.name}@@${book.author}`);

  const load = useCallback(
    async (force = false) => {
      if (!force && !loading) setLoading(true);
      setFailed(false);
      try {
        if (force) clearMirrorCache();
        const data = await fetchBookStoreData(channel);
        setHeroBook(data.heroBook);
        setRankings(data.rankings);
        setAllBooks(data.allBooks);
        loadedChannels.current.add(channel);
      } catch {
        setFailed(true);
      }
      setLoading(false);
      setRefreshing(false);
    },
    [channel, loading],
  );

  useEffect(() => {
    setSwapPages([0, 0, 0]);
    setLoading(true);
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [channel]);

  const openBook = (book: QidianBook) => {
    navigation.navigate('BookDetail', {
      bookName: book.name,
      bookAuthor: book.author,
      bookCover: book.coverUrl,
      bookIntro: book.intro,
    });
  };

  const openSearch = () => navigation.navigate('Search', {});

  const swap = (idx: number) => {
    setSwapPages(prev => {
      const next = [...prev];
      next[idx] = (next[idx] || 0) + 1;
      return next;
    });
  };

  const sectionBooks = (group: RankingGroup, sIdx: number): QidianBook[] => {
    const page = swapPages[sIdx] || 0;
    const pool = group.books;
    if (!pool || pool.length === 0) return [];
    if (pool.length <= 8 || page === 0) return pool.slice(0, 8);
    const start = (page * 8) % pool.length;
    const result: QidianBook[] = [];
    for (let i = 0; i < 8; i++) {
      result.push(pool[(start + i) % pool.length]);
    }
    return result;
  };

  return (
    <SafeAreaView style={[styles.container, {backgroundColor: colors.background}]}>
      {/* 顶栏: 频道 tabs + 搜索 — iOS topBar */}
      <LinearGradient
        colors={[colors.background, colors.card]}
        start={{x: 0, y: 0}}
        end={{x: 0, y: 1}}
        style={styles.topBar}>
        <View style={styles.channelRow}>
          {(['male', 'female', 'publish'] as Channel[]).map(ch => {
            const active = channel === ch;
            return (
              <TouchableOpacity
                key={ch}
                style={styles.channelItem}
                onPress={() => setChannel(ch)}>
                <Text
                  style={[
                    styles.channelLabel,
                    {color: colors.textSecondary},
                    active && {fontSize: 20, fontWeight: '700', color: colors.textPrimary},
                  ]}>
                  {CHANNEL_LABELS[ch]}
                </Text>
                <View
                  style={[
                    styles.channelIndicator,
                    {backgroundColor: colors.primary},
                    !active && styles.channelIndicatorHidden,
                  ]}
                />
              </TouchableOpacity>
            );
          })}
        </View>
        <TouchableOpacity onPress={openSearch} style={styles.searchBtn}>
          <Ionicons name="search" size={20} color={colors.textPrimary} />
        </TouchableOpacity>
      </LinearGradient>
      <View style={[styles.topBarLine, {backgroundColor: colors.isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'}]} />

      {loading && allBooks.length === 0 ? (
        <View style={styles.skeletonWrap}>
          <SkeletonPlaceholder cellW={cellW} cellCoverH={cellCoverH} colors={colors} />
        </View>
      ) : failed && allBooks.length === 0 ? (
        <View style={styles.failedWrap}>
          <Ionicons
            name="wifi-outline"
            size={36}
            color={colors.textSecondary}
            style={{opacity: 0.6}}
          />
          <Text style={[styles.failedText, {color: colors.textSecondary}]}>加载失败，下拉重试</Text>
          <TouchableOpacity style={[styles.retryBtn, {backgroundColor: colors.primary}]} onPress={() => load(true)}>
            <Text style={styles.retryText}>重试</Text>
          </TouchableOpacity>
        </View>
      ) : (
        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.scrollContent}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={() => {
                setRefreshing(true);
                load(true);
              }}
              tintColor={colors.primary}
            />
          }>
          {/* Hero 卡片 — iOS heroCard */}
          {heroBook && (
            <TouchableOpacity
              style={[styles.heroCard, {backgroundColor: colors.card}]}
              activeOpacity={0.8}
              onPress={() => openBook(heroBook)}>
              <View style={{width: 96, height: 128}}>
                <BookCover
                  url={heroBook.coverUrl.replace('/180', '/300')}
                  width={96}
                  height={128}
                  bookTitle={heroBook.name}
                  bookAuthor={heroBook.author}
                  borderRadius={4}
                />
                {isOnShelf(heroBook) && (
                  <View style={styles.shelfBadge}>
                    <Text style={styles.shelfBadgeText}>已在书架</Text>
                  </View>
                )}
                {channel === 'publish' && (
                  <View style={styles.publishChip}>
                    <Text style={styles.publishChipText}>出版</Text>
                  </View>
                )}
              </View>
              <View style={styles.heroMeta}>
                <View style={styles.heroBadgeRow}>
                  <View style={styles.heroBadge}>
                    <Text style={styles.heroBadgeText}>榜首</Text>
                  </View>
                  <Text style={[styles.heroRankName, {color: colors.primary}]}>
                    {heroBook.rankName || '月票榜'}
                  </Text>
                </View>
                <Text style={[styles.heroTitle, {color: colors.textPrimary}]} numberOfLines={2}>
                  {heroBook.name}
                </Text>
                <View style={styles.heroInfoRow}>
                  {heroBook.author ? (
                    <Text style={[styles.heroAuthor, {color: colors.textSecondary}]}>{heroBook.author}</Text>
                  ) : null}
                  {(heroBook.subCategory || heroBook.category) ? (
                    <View style={[styles.heroTag, {backgroundColor: `${colors.primary}1A`}]}>
                      <Text style={[styles.heroTagText, {color: colors.primary}]}>
                        {heroBook.subCategory || heroBook.category}
                      </Text>
                    </View>
                  ) : null}
                </View>
                {heroBook.intro ? (
                  <Text style={[styles.heroIntro, {color: colors.textSecondary}]} numberOfLines={3}>
                    {heroBook.intro}
                  </Text>
                ) : null}
              </View>
            </TouchableOpacity>
          )}

          {/* Banner 行 — iOS bannerRow */}
          <View style={styles.bannerRow}>
            <TouchableOpacity
              style={styles.bannerCard}
              activeOpacity={0.8}
              onPress={() =>
                navigation.navigate('RankDetail', {
                  mode: 'rank',
                  channel,
                  title: '热门排行',
                })
              }>
              <LinearGradient
                colors={['rgba(245,128,82,1)', 'rgba(240,77,77,1)']}
                start={{x: 0, y: 0}}
                end={{x: 1, y: 1}}
                style={styles.bannerGradient}>
                <View style={styles.bannerTextCol}>
                  <Text style={styles.bannerTitle}>热门排行</Text>
                  <Text style={styles.bannerSub}>月票榜 TOP 50</Text>
                </View>
                <Ionicons
                  name="flame"
                  size={30}
                  color="rgba(255,255,255,0.42)"
                />
              </LinearGradient>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.bannerCard}
              activeOpacity={0.8}
              onPress={() => {
                const t = channel === 'publish' ? '出版书库' : '完本书库';
                navigation.navigate('RankDetail', {
                  mode: 'finish',
                  channel,
                  title: t,
                });
              }}>
              <LinearGradient
                colors={['rgba(199,235,212,1)', 'rgba(245,199,128,1)']}
                start={{x: 0, y: 0}}
                end={{x: 1, y: 1}}
                style={styles.bannerGradient}>
                <View style={styles.bannerTextCol}>
                  <Text style={styles.bannerTitle}>
                    {channel === 'publish' ? '出版书库' : '完本书库'}
                  </Text>
                  <Text style={styles.bannerSub}>
                    {channel === 'publish'
                      ? '阅读 · 新书 · 推荐'
                      : '经典完结 50 本'}
                  </Text>
                </View>
                <Ionicons
                  name="library"
                  size={30}
                  color="rgba(255,255,255,0.42)"
                />
              </LinearGradient>
            </TouchableOpacity>
          </View>

          {/* 分区网格 — iOS sectionGrid / sectionRanked */}
          {rankings.map((group, gi) => {
            const isLast = gi === rankings.length - 1;
            const bks = sectionBooks(group, gi);
            if (bks.length === 0) return null;
            return (
              <View key={group.rankType} style={[styles.section, {backgroundColor: colors.card}]}>
                <View style={styles.sectionHeader}>
                  <Text style={[styles.sectionTitle, {color: colors.textPrimary}]}>{group.name}</Text>
                  <View style={styles.sectionHeaderRight}>
                    <TouchableOpacity
                      style={styles.sectionAllBtn}
                      onPress={() =>
                        navigation.navigate('RankDetail', {
                          mode: 'rank',
                          channel,
                          title: group.name,
                          rankType: group.rankType,
                        })
                      }>
                      <View style={styles.sectionAllInner}>
                        <Text style={[styles.sectionAllText, {color: colors.textSecondary}]}>全部</Text>
                        <Ionicons
                          name="chevron-forward"
                          size={11}
                          color={colors.textSecondary}
                        />
                      </View>
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[styles.swapBtn, {backgroundColor: `${colors.primary}1A`}]}
                      onPress={() => swap(gi)}>
                      <View style={styles.swapInner}>
                        <Ionicons
                          name="sync-outline"
                          size={12}
                          color={colors.primary}
                        />
                        <Text style={[styles.swapText, {color: colors.primary}]}>换一批</Text>
                      </View>
                    </TouchableOpacity>
                  </View>
                </View>

                <View style={styles.bookGrid}>
                  {bks.map((item, idx) => (
                    <TouchableOpacity
                      key={`${group.rankType}-${idx}-${item.bid}`}
                      style={{width: cellW}}
                      onPress={() => openBook(item)}
                      activeOpacity={0.7}>
                      <View>
                        <BookCover
                          url={item.coverUrl}
                          width={cellW}
                          height={cellCoverH}
                          bookTitle={item.name}
                          bookAuthor={item.author}
                          borderRadius={4}
                        />
                        {isLast && (
                          <View
                            style={[
                              styles.rankBadge,
                              {backgroundColor: rankColor(idx)},
                            ]}>
                            <Text style={styles.rankBadgeText}>{idx + 1}</Text>
                          </View>
                        )}
                        {!isLast && item.rank === 1 && (
                          <View style={styles.topBadge}>
                            <Text style={styles.topBadgeText}>榜首</Text>
                          </View>
                        )}
                        {!isLast && (item.rank === 2 || item.rank === 3) && (
                          <View style={styles.topBadgeGold}>
                            <Text style={styles.topBadgeText}>
                              TOP{item.rank}
                            </Text>
                          </View>
                        )}
                        {isOnShelf(item) && (
                          <View style={styles.shelfBadge}>
                            <Text style={styles.shelfBadgeText}>已在书架</Text>
                          </View>
                        )}
                        {channel === 'publish' && (
                          <View style={styles.publishChip}>
                            <Text style={styles.publishChipText}>出版</Text>
                          </View>
                        )}
                      </View>
                      <Text style={[styles.cellTitle, {color: colors.textPrimary}]} numberOfLines={1}>
                        {item.name}
                      </Text>
                      {item.author ? (
                        <Text style={[styles.cellAuthor, {color: colors.textSecondary}]} numberOfLines={1}>
                          {item.author}
                        </Text>
                      ) : null}
                      {(item.subCategory || item.category) ? (
                        <Text style={[styles.cellTag, {color: `${colors.primary}D9`}]} numberOfLines={1}>
                          {item.subCategory || item.category}
                        </Text>
                      ) : null}
                    </TouchableOpacity>
                  ))}
                </View>
              </View>
            );
          })}
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

function rankColor(idx: number): string {
  if (idx === 0) return '#EB4545';
  if (idx === 1) return '#F28D2E';
  if (idx === 2) return '#D9B033';
  return 'rgba(0,0,0,0.45)';
}

function SkeletonPlaceholder({cellW, cellCoverH, colors}: {cellW: number; cellCoverH: number; colors: ThemeColors}) {
  return (
    <View style={skStyles.wrap}>
      <View style={[skStyles.hero, {backgroundColor: colors.card}]} />
      <View style={skStyles.bannerRow}>
        <View style={[skStyles.banner, {backgroundColor: colors.card}]} />
        <View style={[skStyles.banner, {backgroundColor: colors.card}]} />
      </View>
      {[0, 1, 2].map(i => (
        <View key={i} style={[skStyles.section, {backgroundColor: colors.card}]}>
          <View style={[skStyles.sectionTitle, {backgroundColor: `${colors.textSecondary}1F`}]} />
          <View style={skStyles.grid}>
            {[0, 1, 2, 3, 4, 5, 6, 7].map(j => (
              <View key={j} style={{width: cellW}}>
                <View style={{width: cellW, height: cellCoverH, borderRadius: 4, backgroundColor: `${colors.textSecondary}1A`}} />
                <View style={[skStyles.cellLine, {backgroundColor: `${colors.textSecondary}14`}]} />
              </View>
            ))}
          </View>
        </View>
      ))}
    </View>
  );
}

const skStyles = StyleSheet.create({
  wrap: {paddingHorizontal: SECTION_PAD, paddingTop: 12},
  hero: {
    height: 156,
    borderRadius: 18, borderCurve: 'continuous' as any,
    marginBottom: 16,
  },
  bannerRow: {flexDirection: 'row', gap: 12, marginBottom: 16},
  banner: {
    flex: 1,
    height: 84,
    borderRadius: 16,
  },
  section: {
    padding: 12,
    borderRadius: 18, borderCurve: 'continuous' as any,
    marginBottom: 16,
  },
  sectionTitle: {
    width: 100,
    height: 20,
    borderRadius: 6,
    marginBottom: 12,
  },
  grid: {flexDirection: 'row', flexWrap: 'wrap', columnGap: GRID_GAP, rowGap: 14},
  cellLine: {
    height: 10,
    borderRadius: 4,
    marginTop: 6,
  },
});

const styles = StyleSheet.create({
  container: {flex: 1},
  scrollContent: {paddingHorizontal: SECTION_PAD, paddingTop: 12, paddingBottom: 92},
  skeletonWrap: {flex: 1},
  failedWrap: {flex: 1, alignItems: 'center', paddingTop: 80},
  failedText: {fontSize: 15, marginTop: 10},
  retryBtn: {
    marginTop: 12,
    paddingHorizontal: 20,
    paddingVertical: 8,
    borderRadius: Radius.md,
  },
  retryText: {color: '#fff', fontWeight: '600'},

  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
    paddingVertical: 10,
  },
  channelRow: {flex: 1, flexDirection: 'row'},
  channelItem: {alignItems: 'center', paddingHorizontal: 14},
  channelLabel: {fontSize: 17},
  channelIndicator: {
    width: 22,
    height: 3,
    borderRadius: 1.5,
    marginTop: 4,
  },
  channelIndicatorHidden: {backgroundColor: 'transparent'},
  searchBtn: {padding: 10},
  topBarLine: {height: 0.5},

  heroCard: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    padding: 14,
    borderRadius: 18, borderCurve: 'continuous' as any,
    marginBottom: 16,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 3},
    shadowOpacity: 0.05,
    shadowRadius: 8,
    elevation: 3,
  },
  heroMeta: {flex: 1, marginLeft: 14},
  heroBadgeRow: {flexDirection: 'row', alignItems: 'center', gap: 6},
  heroBadge: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 10,
    backgroundColor: '#EB4545',
  },
  heroBadgeText: {color: '#fff', fontSize: 11, fontWeight: '800'},
  heroRankName: {fontSize: 11, fontWeight: '600'},
  heroTitle: {fontSize: 20, fontWeight: '700', marginTop: 6},
  heroInfoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 6,
  },
  heroAuthor: {fontSize: 12},
  heroTag: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 999,
  },
  heroTagText: {fontSize: 11, fontWeight: '500'},
  heroIntro: {fontSize: 12, marginTop: 6, lineHeight: 18},

  bannerRow: {flexDirection: 'row', gap: 12, marginBottom: 16},
  bannerCard: {flex: 1, borderRadius: 16, borderCurve: 'continuous' as any, overflow: 'hidden', height: 84},
  bannerGradient: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 14,
  },
  bannerTextCol: {flex: 1},
  bannerTitle: {fontSize: 17, fontWeight: '800', color: '#fff'},
  bannerSub: {
    fontSize: 12,
    fontWeight: '500',
    color: 'rgba(255,255,255,0.92)',
    marginTop: 4,
  },

  section: {
    padding: 12,
    borderRadius: 18, borderCurve: 'continuous' as any,
    marginBottom: 16,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 3},
    shadowOpacity: 0.04,
    shadowRadius: 8,
    elevation: 2,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  sectionTitle: {fontSize: 20, fontWeight: '700'},
  sectionHeaderRight: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  sectionAllBtn: {},
  sectionAllInner: {flexDirection: 'row', alignItems: 'center', gap: 2},
  sectionAllText: {fontSize: 12, fontWeight: '600'},
  swapBtn: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 999,
  },
  swapInner: {flexDirection: 'row', alignItems: 'center', gap: 3},
  swapText: {fontSize: 12, fontWeight: '600'},

  bookGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: GRID_GAP,
    rowGap: 14,
  },
  cellTitle: {fontSize: 12, fontWeight: '600', marginTop: 5},
  cellAuthor: {fontSize: 11, marginTop: 1},
  cellTag: {fontSize: 9, fontWeight: '500', marginTop: 1},

  rankBadge: {
    position: 'absolute',
    top: 4,
    left: 4,
    width: 22,
    height: 22,
    borderRadius: 11,
    justifyContent: 'center',
    alignItems: 'center',
  },
  rankBadgeText: {color: '#fff', fontSize: 11, fontWeight: '800'},
  topBadge: {
    position: 'absolute',
    top: 4,
    left: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
    borderRadius: 999,
    backgroundColor: '#EB4545',
  },
  topBadgeGold: {
    position: 'absolute',
    top: 4,
    left: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
    borderRadius: 999,
    backgroundColor: '#D9B033',
  },
  topBadgeText: {color: '#fff', fontSize: 9, fontWeight: '800'},
  shelfBadge: {
    position: 'absolute',
    bottom: 4,
    right: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
    borderRadius: 999,
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  shelfBadgeText: {color: '#fff', fontSize: 8, fontWeight: '800'},
  publishChip: {
    position: 'absolute',
    bottom: 4,
    left: 4,
    paddingHorizontal: 5,
    paddingVertical: 1,
    borderRadius: 999,
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  publishChipText: {color: '#fff', fontSize: 9, fontWeight: '700'},
});
