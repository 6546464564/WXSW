import React, {useMemo, useState} from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet, Image} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {colors, cardShadow} from '../theme';
import {REFERENCE_PLANTS} from '../data/referencePlants';
import {PLANT_IMAGES} from '../assets/images';
import SearchBar from '../components/SearchBar';
import ScreenShell from '../components/ScreenShell';
import {useLayout} from '../hooks/useLayout';

export default function GuideScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  const {columns, padX, isWide} = useLayout();
  const cardWidth = columns >= 3 ? '31.5%' : isWide ? '48.5%' : '100%';
  const [cat, setCat] = useState('全部');
  const [query, setQuery] = useState('');
  const cats = ['全部', '公园', '阳台', '野外', '校园'];

  const list = useMemo(() => {
    let result = cat === '全部' ? REFERENCE_PLANTS : REFERENCE_PLANTS.filter(p => p.habitat.includes(cat as any));
    const q = query.trim().toLowerCase();
    if (q) {
      result = result.filter(
        p => p.name.includes(q) || p.latin.toLowerCase().includes(q) || p.family.includes(q),
      );
    }
    return result;
  }, [cat, query]);

  return (
    <ScreenShell style={{paddingTop: insets.top}}>
      <View style={{paddingHorizontal: padX}}>
        <Text style={styles.title}>植物图志</Text>
        <Text style={styles.sub}>离线参考 · 共 {REFERENCE_PLANTS.length} 种 · 仅供观察辅助</Text>
        <SearchBar value={query} onChangeText={setQuery} placeholder="搜索名称、拉丁名或科属…" />
      </View>

      <View style={{paddingHorizontal: padX}}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.filterRow}>
          {cats.map(c => (
            <TouchableOpacity key={c} style={[styles.chip, cat === c && styles.chipActive]} onPress={() => setCat(c)}>
              <Text style={[styles.chipText, cat === c && styles.chipTextActive]}>{c}</Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      </View>

      <ScrollView contentContainerStyle={{paddingHorizontal: padX, paddingBottom: insets.bottom + 40}}>
        <View style={[styles.grid, isWide && styles.gridWide]}>
        {list.map(p => (
          <TouchableOpacity
            key={p.id}
            style={[styles.card, cardShadow, isWide && {width: cardWidth}]}
            activeOpacity={0.75}
            onPress={() => navigation.navigate('GuideDetail', {id: p.id})}>
            <Image source={PLANT_IMAGES[p.imageAsset]} style={styles.thumb} />
            <Text style={styles.name}>{p.name}</Text>
            <Text style={styles.latin} numberOfLines={1}>{p.latin}</Text>
            <Text style={styles.family} numberOfLines={1}>{p.family}</Text>
          </TouchableOpacity>
        ))}
        </View>
        {list.length === 0 && (
          <View style={styles.empty}>
            <Text style={styles.emptyText}>未找到匹配植物</Text>
          </View>
        )}
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginTop: 8},
  sub: {fontSize: 12, color: colors.textMuted, marginTop: 4, marginBottom: 4},
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
  card: {
    backgroundColor: colors.card,
    borderRadius: 14,
    padding: 12,
  },
  thumb: {width: '100%', height: 100, borderRadius: 10, marginBottom: 8},
  name: {fontSize: 16, fontWeight: '700', color: colors.text},
  latin: {fontSize: 11, color: colors.textMuted, fontStyle: 'italic', marginTop: 2},
  family: {fontSize: 12, color: colors.textSecondary, marginTop: 2},
  empty: {alignItems: 'center', paddingVertical: 40},
  emptyText: {fontSize: 14, color: colors.textMuted},
});
