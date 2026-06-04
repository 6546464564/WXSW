/**
 * 万象书屋 RN · 排行详情 / 书库详情
 * 对齐 iOS: RankDetailView.swift
 *
 * mode:
 *  - 'rank': 热门排行 TOP50 (yuepiaoTop50)
 *  - 'finish': 完本书库 / 出版书库
 */

import React, {useEffect, useState, useCallback, useMemo} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  FlatList,
  StyleSheet,
  RefreshControl,
  ActivityIndicator,
} from 'react-native';
import {useRoute, useNavigation, RouteProp} from '@react-navigation/native';
import {NativeStackNavigationProp} from '@react-navigation/native-stack';
import Ionicons from 'react-native-vector-icons/Ionicons';
import BookCover from '../../components/BookCover';
import {fetchRankBooks, fetchFinishLibrary, QidianBook, Channel} from '../../api/bookstore';
import {useThemeColors, Radius} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';
import {useBookshelfStore} from '../../store/bookshelfStore';

type Nav = NativeStackNavigationProp<RootStackParamList>;

export default function RankDetailScreen() {
  const colors = useThemeColors();
  const route = useRoute<RouteProp<RootStackParamList, 'RankDetail'>>();
  const navigation = useNavigation<Nav>();
  const {mode, channel, title, rankType} = route.params;

  const [books, setBooks] = useState<QidianBook[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const shelfBooks = useBookshelfStore(s => s.books);
  const shelfKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const b of shelfBooks) {
      keys.add(`${b.name}@@${b.author}`);
    }
    return keys;
  }, [shelfBooks]);
  const isOnShelf = (book: QidianBook) => shelfKeys.has(`${book.name}@@${book.author}`);

  const load = useCallback(async () => {
    try {
      const data = mode === 'rank'
        ? await fetchRankBooks(channel, rankType || 'fyRank')
        : await fetchFinishLibrary(channel);
      setBooks(data);
    } catch { /* noop */ }
    setLoading(false);
    setRefreshing(false);
  }, [mode, channel, rankType]);

  useEffect(() => { load(); }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

  const openBook = (book: QidianBook) => {
    navigation.navigate('BookDetail', {
      bookName: book.name,
      bookAuthor: book.author,
      bookCover: book.coverUrl,
      bookIntro: book.intro,
    });
  };

  const renderItem = ({item, index}: {item: QidianBook; index: number}) => {
    const rank = index + 1;
    const tag = item.subCategory || item.category;
    const onShelf = isOnShelf(item);
    return (
      <TouchableOpacity
        style={[styles.row, {backgroundColor: colors.card}]}
        activeOpacity={0.7}
        onPress={() => openBook(item)}>
        <View>
          <BookCover
            url={item.coverUrl?.replace('/180', '/300')}
            width={72}
            height={96}
            bookTitle={item.name}
            bookAuthor={item.author}
            borderRadius={6}
          />
          <View style={[styles.rankBadge, {backgroundColor: badgeColor(rank)}]}>
            <Text style={styles.rankBadgeText}>{rank}</Text>
          </View>
          {onShelf && (
            <View style={styles.shelfBadge}>
              <Text style={styles.shelfBadgeText}>已在书架</Text>
            </View>
          )}
        </View>
        <View style={styles.rowMeta}>
          <Text style={[styles.rowTitle, {color: colors.textPrimary}]} numberOfLines={1}>{item.name}</Text>
          <View style={styles.rowInfoRow}>
            {item.author ? <Text style={[styles.rowAuthor, {color: colors.textSecondary}]}>{item.author}</Text> : null}
            {tag ? (
              <View style={[styles.rowTag, {backgroundColor: `${colors.primary}1A`}]}>
                <Text style={[styles.rowTagText, {color: colors.primary}]}>{tag}</Text>
              </View>
            ) : null}
            {item.wordCount ? (
              <Text style={[styles.rowWordCount, {color: `${colors.textSecondary}D9`}]}>{item.wordCount}</Text>
            ) : null}
          </View>
          {item.rankCount ? (
            <Text style={[styles.rowRankCount, {color: colors.primary}]}>{item.rankCount}</Text>
          ) : null}
          {item.intro ? (
            <Text style={[styles.rowIntro, {color: colors.textSecondary}]} numberOfLines={3}>{item.intro}</Text>
          ) : null}
        </View>
      </TouchableOpacity>
    );
  };

  return (
    <View style={[styles.container, {backgroundColor: colors.background}]}>
      {loading && books.length === 0 ? (
        <ActivityIndicator style={{marginTop: 80}} color={colors.primary} size="large" />
      ) : books.length === 0 ? (
        <View style={styles.emptyWrap}>
          <Ionicons name="tray-outline" size={36} color={colors.textSecondary} style={{opacity: 0.55}} />
          <Text style={[styles.emptyText, {color: colors.textSecondary}]}>加载失败，下拉重试</Text>
        </View>
      ) : (
        <FlatList
          data={books}
          keyExtractor={(item, idx) => `${item.bid}-${idx}`}
          renderItem={renderItem}
          contentContainerStyle={styles.listContent}
          showsVerticalScrollIndicator={false}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.primary} />
          }
        />
      )}
    </View>
  );
}

function badgeColor(rank: number): string {
  if (rank === 1) return '#EB4545';
  if (rank === 2) return '#F28D2E';
  if (rank === 3) return '#D9B033';
  return 'rgba(0,0,0,0.45)';
}

const styles = StyleSheet.create({
  container: {flex: 1},
  listContent: {paddingTop: 8, paddingBottom: 40, paddingHorizontal: 12},
  emptyWrap: {flex: 1, alignItems: 'center', paddingTop: 100},
  emptyText: {fontSize: 15, marginTop: 10},

  row: {
    flexDirection: 'row',
    padding: 12,
    borderRadius: 14,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: {width: 0, height: 2},
    shadowOpacity: 0.04,
    shadowRadius: 6,
    elevation: 2,
  },
  rankBadge: {
    position: 'absolute',
    top: 4,
    left: 4,
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 999,
  },
  rankBadgeText: {color: '#fff', fontSize: 12, fontWeight: '700'},
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

  rowMeta: {flex: 1, marginLeft: 12, justifyContent: 'center'},
  rowTitle: {fontSize: 17, fontWeight: '600'},
  rowInfoRow: {flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 5},
  rowAuthor: {fontSize: 12},
  rowTag: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 999,
  },
  rowTagText: {fontSize: 10, fontWeight: '500'},
  rowWordCount: {fontSize: 10, marginTop: 3},
  rowRankCount: {fontSize: 10, marginTop: 3},
  rowIntro: {fontSize: 12, marginTop: 4, lineHeight: 18},
});
