import React, {useCallback, useMemo, useState} from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {colors, seasons, habitats, cardShadow} from '../theme';
import {loadObservations} from '../storage';
import PlantThumb from '../components/PlantThumb';
import SearchBar from '../components/SearchBar';
import ScreenShell from '../components/ScreenShell';
import {useLayout} from '../hooks/useLayout';
import type {Observation, Season, Habitat} from '../types';

type Filter = '全部' | Season | Habitat;

export default function AtlasScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  const {isWide, columns, padX} = useLayout();
  const cardWidth = columns >= 3 ? '31.5%' : isWide ? '48.5%' : '100%';
  const [list, setList] = useState<Observation[]>([]);
  const [filter, setFilter] = useState<Filter>('全部');
  const [query, setQuery] = useState('');

  useFocusEffect(
    useCallback(() => {
      loadObservations().then(setList);
    }, []),
  );

  const filters: Filter[] = ['全部', ...seasons, ...habitats];

  const filtered = useMemo(() => {
    let result = list;
    if (filter !== '全部') {
      if ((seasons as readonly string[]).includes(filter)) {
        result = result.filter(o => o.season === filter);
      } else {
        result = result.filter(o => o.habitat === filter);
      }
    }
    const q = query.trim().toLowerCase();
    if (q) {
      result = result.filter(
        o => o.plantName.toLowerCase().includes(q) || o.location.toLowerCase().includes(q),
      );
    }
    return result;
  }, [list, filter, query]);

  const grouped = useMemo(() => {
    const map = new Map<string, {item: Observation; count: number}>();
    filtered.forEach(o => {
      const prev = map.get(o.plantName);
      if (!prev) map.set(o.plantName, {item: o, count: 1});
      else map.set(o.plantName, {item: prev.item, count: prev.count + 1});
    });
    return Array.from(map.values());
  }, [filtered]);

  return (
    <ScreenShell style={{paddingTop: insets.top}}>
      <View style={{paddingHorizontal: padX}}>
        <Text style={styles.title}>我的图鉴</Text>
        <Text style={styles.sub}>共收录 {grouped.length} 种 · {filtered.length} 条记录</Text>
        <SearchBar value={query} onChangeText={setQuery} placeholder="搜索植物或地点…" />
      </View>

      <View style={{paddingHorizontal: padX}}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.filterRow}>
          {filters.map(f => (
            <TouchableOpacity
              key={f}
              style={[styles.chip, filter === f && styles.chipActive]}
              onPress={() => setFilter(f)}>
              <Text style={[styles.chipText, filter === f && styles.chipTextActive]}>{f}</Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      </View>

      <ScrollView contentContainerStyle={{paddingHorizontal: padX, paddingBottom: insets.bottom + 40}}>
        <View style={[styles.grid, isWide && styles.gridWide]}>
          {grouped.map(({item, count}) => (
            <TouchableOpacity
              key={item.plantName}
              style={[styles.row, cardShadow, isWide && {width: cardWidth}]}
              activeOpacity={0.7}
              onPress={() => navigation.navigate('Species', {plantName: item.plantName})}>
              <PlantThumb item={item} size={52} />
              <View style={styles.rowBody}>
                <Text style={styles.name}>{item.plantName}</Text>
                <Text style={styles.meta}>{item.habitat} · {item.date}</Text>
                {count > 1 && <Text style={styles.badge}>{count} 次观察</Text>}
              </View>
            </TouchableOpacity>
          ))}
        </View>
        {grouped.length === 0 && (
          <View style={styles.empty}>
            <Text style={styles.emptyIcon}>🌿</Text>
            <Text style={styles.emptyText}>{query ? '未找到匹配记录' : '暂无记录，去首页新增一次观察吧'}</Text>
          </View>
        )}
        {grouped.length > 0 && grouped.length < 8 && (
          <View style={styles.footer}>
            <Text style={styles.footerText}>🌱 继续探索，丰富你的植物图鉴</Text>
          </View>
        )}
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginTop: 8},
  sub: {fontSize: 13, color: colors.textMuted, marginTop: 4, marginBottom: 4},
  filterRow: {flexDirection: 'row' as const, gap: 8, paddingBottom: 12},
  chip: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 14,
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.border,
  },
  chipActive: {backgroundColor: colors.primaryLight, borderColor: colors.primaryLight},
  chipText: {fontSize: 14, color: colors.textSecondary, includeFontPadding: false},
  chipTextActive: {color: '#fff', fontWeight: '600'},
  grid: {gap: 12},
  gridWide: {flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between'},
  row: {
    flexDirection: 'row',
    gap: 12,
    backgroundColor: colors.card,
    borderRadius: 14,
    padding: 12,
  },
  rowBody: {flex: 1, justifyContent: 'center'},
  name: {fontSize: 16, fontWeight: '700', color: colors.text},
  meta: {fontSize: 12, color: colors.textSecondary, marginTop: 2},
  badge: {fontSize: 11, color: colors.primaryLight, fontWeight: '600', marginTop: 4},
  empty: {alignItems: 'center', paddingVertical: 60},
  emptyIcon: {fontSize: 36, marginBottom: 10},
  emptyText: {fontSize: 14, color: colors.textMuted, textAlign: 'center'},
  footer: {alignItems: 'center', paddingVertical: 28},
  footerText: {fontSize: 13, color: colors.textMuted},
});
