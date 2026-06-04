/**
 * 万象书屋 RN · 书架
 * 1:1 对齐 iOS: BookshelfView.swift
 */

import React, {useState, useCallback, useMemo} from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  ScrollView,
  Alert,
  RefreshControl,
  StyleSheet,
  ActionSheetIOS,
  Platform,
  Dimensions,
  Modal,
  TextInput,
} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {NativeStackNavigationProp} from '@react-navigation/native-stack';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {useBookshelfStore, ShelfBook} from '../../store/bookshelfStore';
import BookCover from '../../components/BookCover';
import {useThemeColors, Radius} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';

type Nav = NativeStackNavigationProp<RootStackParamList>;

const SCREEN_W = Dimensions.get('window').width;
const GRID_COLS = 3;
const GRID_H_PAD = 12;
const GRID_GAP = 12;
const CARD_W = (SCREEN_W - GRID_H_PAD * 2 - GRID_GAP * (GRID_COLS - 1)) / GRID_COLS;
const COVER_H = (CARD_W * 4.2) / 3;

export default function BookshelfScreen() {
  const colors = useThemeColors();
  const books = useBookshelfStore(s => s.books);
  const groups = useBookshelfStore(s => s.groups);
  const removeBook = useBookshelfStore(s => s.removeBook);
  const moveToGroup = useBookshelfStore(s => s.moveToGroup);
  const addGroup = useBookshelfStore(s => s.addGroup);
  const removeGroup = useBookshelfStore(s => s.removeGroup);
  const renameGroup = useBookshelfStore(s => s.renameGroup);
  const navigation = useNavigation<Nav>();
  const [selectedGroup, setSelectedGroup] = useState('全部');
  const [refreshing, setRefreshing] = useState(false);
  const [menuVisible, setMenuVisible] = useState(false);
  const [isGrid, setIsGrid] = useState(true);
  const [showGroupManager, setShowGroupManager] = useState(false);
  const [newGroupName, setNewGroupName] = useState('');
  const [moveBookTarget, setMoveBookTarget] = useState<ShelfBook | null>(null);
  const insets = useSafeAreaInsets();

  const allGroups = ['全部', '未分组', ...groups];

  const filteredBooks = useMemo(() => {
    if (selectedGroup === '全部') return books;
    if (selectedGroup === '未分组') return books.filter(b => !b.group);
    return books.filter(b => b.group === selectedGroup);
  }, [books, selectedGroup]);

  const openBook = (book: ShelfBook) => {
    navigation.navigate('Reader', {
      bookUrl: book.bookUrl,
      chapterIndex: book.lastChapterIndex,
    });
  };

  const openSearch = () => navigation.navigate('Search', {});

  const onLongPress = (book: ShelfBook) => {
    const options = ['置顶', '下载到本地', '移到分组', '从书架删除', '取消'];
    if (Platform.OS === 'ios') {
      ActionSheetIOS.showActionSheetWithOptions(
        {options, destructiveButtonIndex: 3, cancelButtonIndex: 4},
        idx => {
          if (idx === 2) setMoveBookTarget(book);
          if (idx === 3) confirmDelete(book);
        },
      );
    } else {
      Alert.alert(`「${book.name}」`, '', [
        {text: '置顶', onPress: () => {}},
        {text: '移到分组', onPress: () => setMoveBookTarget(book)},
        {text: '从书架删除', style: 'destructive', onPress: () => removeBook(book.id)},
        {text: '取消', style: 'cancel'},
      ]);
    }
  };

  const confirmDelete = (book: ShelfBook) => {
    Alert.alert(`确认删除「${book.name}」吗?`, '', [
      {text: '取消', style: 'cancel'},
      {text: '从书架删除', style: 'destructive', onPress: () => removeBook(book.id)},
    ]);
  };

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    setTimeout(() => setRefreshing(false), 800);
  }, []);

  const progress = (book: ShelfBook) => {
    if (!book.totalChapters || book.totalChapters <= 0) return 0;
    return Math.min(1, (book.lastChapterIndex + 1) / book.totalChapters);
  };

  const progressText = (book: ShelfBook) => {
    if (!book.totalChapters || book.totalChapters <= 0) return '未开始';
    const p = Math.round(progress(book) * 100);
    return `${p}%`;
  };

  const gridKey = useMemo(() => `grid-${isGrid}`, [isGrid]);

  return (
    <View style={[styles.container, {paddingTop: insets.top, backgroundColor: colors.background}]}>
      <View style={styles.navBar}>
        <View style={styles.navSide} />
        <Text style={[styles.navTitle, {color: colors.textPrimary}]}>书架</Text>
        <View style={[styles.navSide, styles.navRight]}>
          <TouchableOpacity
            style={styles.navBtn}
            onPress={openSearch}
            hitSlop={{top: 8, bottom: 8, left: 8, right: 8}}>
            <Ionicons name="search" size={20} color={colors.textPrimary} />
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.navBtn}
            onPress={() => setMenuVisible(!menuVisible)}
            hitSlop={{top: 8, bottom: 8, left: 8, right: 8}}>
            <Ionicons
              name="ellipsis-horizontal-circle-outline"
              size={22}
              color={colors.textPrimary}
            />
          </TouchableOpacity>
        </View>
      </View>
      <View style={[styles.navSeparator, {backgroundColor: colors.divider}]} />

      {menuVisible && (
        <>
          <TouchableOpacity
            style={styles.menuBackdrop}
            activeOpacity={1}
            onPress={() => setMenuVisible(false)}
          />
          <View style={[styles.menu, {backgroundColor: colors.card}]}>
            {[
              {label: '更新目录', icon: 'refresh-outline', action: () => Alert.alert('更新目录', `将更新 ${books.length} 本书的目录`)},
              {label: '添加本地', icon: 'document-attach-outline', action: () => Alert.alert('添加本地', '本地导入功能开发中')},
              {label: '下载中心', icon: 'download-outline', action: () => navigation.navigate('DownloadCenter')},
              {label: '分组管理', icon: 'folder-open-outline', action: () => setShowGroupManager(true)},
              {label: isGrid ? '列表布局' : '网格布局', icon: isGrid ? 'list-outline' : 'grid-outline', action: () => setIsGrid(!isGrid)},
            ].map(item => (
              <TouchableOpacity
                key={item.label}
                style={styles.menuItem}
                onPress={() => { setMenuVisible(false); item.action(); }}>
                <Ionicons name={item.icon} size={17} color={colors.textSecondary} style={styles.menuItemIcon} />
                <Text style={[styles.menuText, {color: colors.textPrimary}]}>{item.label}</Text>
              </TouchableOpacity>
            ))}
          </View>
        </>
      )}

      {/* ===== 分组横栏 =====
       * iOS: ScrollView(.horizontal) > HStack(spacing: 8)
       * .padding(.horizontal) = 16  .padding(.vertical, 8) = 8
       * chip: .padding(.horizontal, 10).padding(.vertical, 6)
       * text: .font(.caption) = 12pt
       * "...": Image(systemName: "ellipsis") .font(.caption)
       *        Capsule().stroke(Color.gray.opacity(0.4))
       */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.groupBarWrap}
        contentContainerStyle={styles.groupBar}>
        {allGroups.map(g => {
          const selected = selectedGroup === g;
          const count = g === '全部' ? books.length : g === '未分组' ? books.filter(b => !b.group).length : books.filter(b => b.group === g).length;
          return (
            <TouchableOpacity
              key={g}
              style={[
                styles.groupChip,
                selected && {backgroundColor: `${colors.primary}2E`},
              ]}
              onPress={() => setSelectedGroup(g)}>
              <Text
                style={[
                  styles.groupText,
                  {color: colors.textPrimary},
                  selected && {color: colors.primary, fontWeight: '600'},
                ]}>
                {g} {count > 0 ? `(${count})` : ''}
              </Text>
            </TouchableOpacity>
          );
        })}
        <TouchableOpacity style={styles.groupMoreBtn} onPress={() => setShowGroupManager(true)}>
          <Ionicons name="ellipsis-horizontal" size={12} color={colors.textSecondary} />
        </TouchableOpacity>
      </ScrollView>

      {/* ===== 内容区 ===== */}
      {filteredBooks.length === 0 && books.length === 0 ? (
        <View style={styles.empty}>
          <Ionicons
            name="library-outline"
            size={64}
            color={colors.textSecondary}
            style={{opacity: 0.6}}
          />
          <Text style={[styles.emptyTitle, {color: colors.textSecondary}]}>书架还空着</Text>
          <Text style={[styles.emptyHint, {color: colors.textSecondary}]}>先去搜索书籍添加吧!</Text>
          <TouchableOpacity style={styles.emptyBtn} onPress={openSearch}>
            <View style={[styles.emptyBtnInner, {backgroundColor: colors.primary}]}>
              <Ionicons name="search" size={14} color="#fff" />
              <Text style={styles.emptyBtnText}>搜索书籍</Text>
            </View>
          </TouchableOpacity>
        </View>
      ) : filteredBooks.length === 0 ? (
        <View style={styles.empty}>
          <Text style={[styles.emptyHint, {color: colors.textSecondary}]}>该分组暂无书籍</Text>
        </View>
      ) : isGrid ? (
        <FlatList
          key={gridKey}
          data={filteredBooks}
          numColumns={GRID_COLS}
          keyExtractor={item => item.id}
          contentContainerStyle={styles.gridContent}
          columnWrapperStyle={styles.gridRow}
          showsVerticalScrollIndicator={false}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.primary} />
          }
          renderItem={({item}) => (
            <TouchableOpacity
              style={styles.gridCard}
              onPress={() => openBook(item)}
              onLongPress={() => onLongPress(item)}
              activeOpacity={0.7}>
              <View style={styles.coverWrap}>
                <BookCover url={item.coverUrl} width={CARD_W} height={COVER_H} bookTitle={item.name} bookAuthor={item.author} borderRadius={6} />
                {progress(item) > 0 && (
                  <View style={styles.progressBarBg}>
                    <View style={[styles.progressBarFill, {width: `${progress(item) * 100}%`, backgroundColor: colors.primary}]} />
                  </View>
                )}
              </View>
              <Text style={[styles.bookName, {color: colors.textPrimary}]} numberOfLines={1}>{item.name}</Text>
              {item.author ? <Text style={[styles.bookAuthor, {color: colors.textSecondary}]} numberOfLines={1}>{item.author}</Text> : null}
              <Text style={[styles.bookProgress, {color: colors.textSecondary}]}>{progressText(item)}</Text>
            </TouchableOpacity>
          )}
        />
      ) : (
        <FlatList
          key={gridKey}
          data={filteredBooks}
          keyExtractor={item => item.id}
          showsVerticalScrollIndicator={false}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.primary} />
          }
          renderItem={({item}) => (
            <TouchableOpacity
              style={styles.listRow}
              onPress={() => openBook(item)}
              onLongPress={() => onLongPress(item)}
              activeOpacity={0.7}>
              <BookCover url={item.coverUrl} width={50} height={70} bookTitle={item.name} bookAuthor={item.author} borderRadius={4} />
              <View style={styles.listInfo}>
                <Text style={[styles.listName, {color: colors.textPrimary}]} numberOfLines={1}>{item.name}</Text>
                <Text style={[styles.listAuthor, {color: colors.textSecondary}]} numberOfLines={1}>{item.author || ''}</Text>
                <View style={styles.listProgressRow}>
                  {item.totalChapters && item.totalChapters > 0 ? (
                    <View style={[styles.listProgressBg, {backgroundColor: colors.divider}]}>
                      <View style={[styles.listProgressFill, {width: `${progress(item) * 100}%`, backgroundColor: colors.primary}]} />
                    </View>
                  ) : null}
                  <Text style={[styles.listProgressText, {color: colors.textSecondary}]}>{progressText(item)}</Text>
                </View>
              </View>
            </TouchableOpacity>
          )}
        />
      )}
      {/* 分组管理 Modal */}
      <Modal visible={showGroupManager} transparent animationType="slide" onRequestClose={() => setShowGroupManager(false)}>
        <View style={gmStyles.overlay}>
          <TouchableOpacity style={gmStyles.backdrop} activeOpacity={1} onPress={() => setShowGroupManager(false)} />
          <View style={[gmStyles.panel, {backgroundColor: colors.card}]}>
            <View style={gmStyles.header}>
              <Text style={[gmStyles.title, {color: colors.textPrimary}]}>分组管理</Text>
              <TouchableOpacity onPress={() => setShowGroupManager(false)}>
                <Text style={[gmStyles.close, {color: colors.textSecondary}]}>✕</Text>
              </TouchableOpacity>
            </View>
            <View style={gmStyles.addRow}>
              <TextInput
                style={[gmStyles.input, {color: colors.textPrimary, borderColor: colors.divider}]}
                placeholder="新分组名称"
                placeholderTextColor={colors.textSecondary}
                value={newGroupName}
                onChangeText={setNewGroupName}
              />
              <TouchableOpacity
                style={[gmStyles.addBtn, {backgroundColor: colors.primary}]}
                onPress={() => {
                  const n = newGroupName.trim();
                  if (n) { addGroup(n); setNewGroupName(''); }
                }}>
                <Text style={gmStyles.addBtnText}>添加</Text>
              </TouchableOpacity>
            </View>
            <FlatList
              data={groups}
              keyExtractor={item => item}
              renderItem={({item}) => (
                <View style={gmStyles.row}>
                  <Text style={[gmStyles.rowName, {color: colors.textPrimary}]}>{item}</Text>
                  <View style={gmStyles.rowActions}>
                    <TouchableOpacity onPress={() => {
                      Alert.prompt?.('重命名分组', '', (text: string) => {
                        if (text.trim()) renameGroup(item, text.trim());
                      }, 'plain-text', item);
                      if (!Alert.prompt) {
                        Alert.alert('重命名', `当前名称: ${item}`, [
                          {text: '取消', style: 'cancel'},
                          {text: '确定', onPress: () => renameGroup(item, item)},
                        ]);
                      }
                    }}>
                      <Ionicons name="pencil-outline" size={18} color={colors.textSecondary} />
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => {
                      Alert.alert('删除分组', `确认删除「${item}」？该分组中的书将移到未分组`, [
                        {text: '取消', style: 'cancel'},
                        {text: '删除', style: 'destructive', onPress: () => removeGroup(item)},
                      ]);
                    }}>
                      <Ionicons name="trash-outline" size={18} color="#e74c3c" />
                    </TouchableOpacity>
                  </View>
                </View>
              )}
              ListEmptyComponent={<Text style={[gmStyles.empty, {color: colors.textSecondary}]}>暂无自定义分组</Text>}
            />
          </View>
        </View>
      </Modal>

      {/* 移到分组 Modal */}
      <Modal visible={!!moveBookTarget} transparent animationType="fade" onRequestClose={() => setMoveBookTarget(null)}>
        <View style={gmStyles.overlay}>
          <TouchableOpacity style={gmStyles.backdrop} activeOpacity={1} onPress={() => setMoveBookTarget(null)} />
          <View style={[gmStyles.panel, {backgroundColor: colors.card, maxHeight: '50%'}]}>
            <View style={gmStyles.header}>
              <Text style={[gmStyles.title, {color: colors.textPrimary}]}>移到分组</Text>
              <TouchableOpacity onPress={() => setMoveBookTarget(null)}>
                <Text style={[gmStyles.close, {color: colors.textSecondary}]}>✕</Text>
              </TouchableOpacity>
            </View>
            <FlatList
              data={['未分组', ...groups]}
              keyExtractor={item => item}
              renderItem={({item}) => {
                const isCurrent = (item === '未分组' && !moveBookTarget?.group) || moveBookTarget?.group === item;
                return (
                  <TouchableOpacity
                    style={[gmStyles.moveRow, isCurrent && {backgroundColor: `${colors.primary}10`}]}
                    onPress={() => {
                      if (moveBookTarget) {
                        moveToGroup(moveBookTarget.id, item === '未分组' ? '' : item);
                        setMoveBookTarget(null);
                      }
                    }}>
                    <Text style={[gmStyles.rowName, {color: isCurrent ? colors.primary : colors.textPrimary}]}>{item}</Text>
                    {isCurrent && <Text style={{color: colors.primary, fontWeight: '600'}}>✓</Text>}
                  </TouchableOpacity>
                );
              }}
            />
          </View>
        </View>
      </Modal>
    </View>
  );
}

const gmStyles = StyleSheet.create({
  overlay: {flex: 1, justifyContent: 'flex-end'},
  backdrop: {flex: 1, backgroundColor: 'rgba(0,0,0,0.4)'},
  panel: {maxHeight: '60%', borderTopLeftRadius: 16, borderTopRightRadius: 16},
  header: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', padding: 16, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#ddd'},
  title: {fontSize: 16, fontWeight: '600'},
  close: {fontSize: 18, padding: 4},
  addRow: {flexDirection: 'row', alignItems: 'center', padding: 12, gap: 8},
  input: {flex: 1, height: 36, borderWidth: 1, borderRadius: 8, paddingHorizontal: 10, fontSize: 14},
  addBtn: {height: 36, paddingHorizontal: 14, borderRadius: 8, justifyContent: 'center'},
  addBtnText: {color: '#fff', fontSize: 14, fontWeight: '500'},
  row: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingVertical: 14, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#eee'},
  rowName: {fontSize: 15},
  rowActions: {flexDirection: 'row', gap: 16},
  moveRow: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingVertical: 14, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#eee'},
  empty: {textAlign: 'center', padding: 30, fontSize: 14},
});

const styles = StyleSheet.create({
  container: {flex: 1},

  navBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    height: 44,
    paddingHorizontal: 16,
  },
  navSide: {flex: 1},
  navTitle: {fontSize: 17, fontWeight: '600', textAlign: 'center'},
  navRight: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    alignItems: 'center',
    gap: 4,
  },
  navBtn: {
    width: 32,
    height: 32,
    justifyContent: 'center',
    alignItems: 'center',
  },
  navSeparator: {height: StyleSheet.hairlineWidth},

  menuBackdrop: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 99,
  },
  menu: {
    position: 'absolute',
    top: 90,
    right: 16,
    borderRadius: Radius.md,
    paddingVertical: 4,
    minWidth: 160,
    zIndex: 100,
    ...Platform.select({
      ios: {shadowColor: '#000', shadowOffset: {width: 0, height: 4}, shadowOpacity: 0.15, shadowRadius: 12},
      android: {elevation: 8},
    }),
  },
  menuItem: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 11,
    gap: 10,
  },
  menuItemIcon: {width: 22, textAlign: 'center'},
  menuText: {fontSize: 15},

  groupBarWrap: {flexGrow: 0},
  groupBar: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 8,
    alignItems: 'center',
  },
  groupChip: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 999,
    backgroundColor: 'rgba(128,128,128,0.12)',
  },
  groupText: {fontSize: 12, fontWeight: '400'},
  groupMoreBtn: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 999,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(128,128,128,0.4)',
    justifyContent: 'center',
    alignItems: 'center',
  },

  gridContent: {
    paddingHorizontal: GRID_H_PAD,
    paddingVertical: 12,
    paddingBottom: 40,
  },
  gridRow: {gap: GRID_GAP, marginBottom: 16},
  gridCard: {width: CARD_W, alignItems: 'flex-start'},
  coverWrap: {width: CARD_W},
  progressBarBg: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    height: 3,
    borderBottomLeftRadius: 6,
    borderBottomRightRadius: 6,
    overflow: 'hidden',
  },
  progressBarFill: {height: 3},
  bookName: {fontSize: 12, marginTop: 6, lineHeight: 16},
  bookAuthor: {fontSize: 10, marginTop: 1},
  bookProgress: {fontSize: 11, marginTop: 1},

  listRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 12,
  },
  listInfo: {flex: 1, gap: 4},
  listName: {fontSize: 15, fontWeight: '500'},
  listAuthor: {fontSize: 11},
  listProgressRow: {flexDirection: 'row', alignItems: 'center', gap: 8},
  listProgressBg: {
    width: 90,
    height: 4,
    borderRadius: 2,
    overflow: 'hidden',
  },
  listProgressFill: {height: 4, borderRadius: 2},
  listProgressText: {fontSize: 11},

  empty: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingBottom: 60,
  },
  emptyTitle: {fontSize: 22, fontWeight: '500', marginTop: 16},
  emptyHint: {fontSize: 15, opacity: 0.8, marginTop: 16},
  emptyBtn: {marginTop: 24},
  emptyBtnInner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 999,
  },
  emptyBtnText: {color: '#fff', fontSize: 15, fontWeight: '500'},
});
