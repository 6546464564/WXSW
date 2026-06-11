import React, {useCallback, useState} from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {colors, cardShadow} from '../theme';
import {groupObservationsByMonth, loadObservations} from '../storage';
import PlantThumb from '../components/PlantThumb';
import type {Observation} from '../types';

function formatMonth(ym: string) {
  const [y, m] = ym.split('-');
  return `${y}年${Number(m)}月`;
}

export default function CalendarScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  const [groups, setGroups] = useState<{ym: string; items: Observation[]}[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadObservations().then(list => setGroups(groupObservationsByMonth(list)));
    }, []),
  );

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <Text style={styles.title}>观察日历</Text>
      <Text style={styles.sub}>按月份浏览你的全部记录</Text>
      <ScrollView contentContainerStyle={{padding: 20, paddingBottom: insets.bottom + 40}}>
        {groups.map(({ym, items}) => (
          <View key={ym} style={styles.section}>
            <View style={styles.monthRow}>
              <Text style={styles.month}>{formatMonth(ym)}</Text>
              <Text style={styles.count}>{items.length} 条</Text>
            </View>
            {items.map(item => (
              <TouchableOpacity
                key={item.id}
                style={[styles.row, cardShadow]}
                activeOpacity={0.75}
                onPress={() => navigation.navigate('ObservationDetail', {id: item.id})}>
                <PlantThumb item={item} size={48} />
                <View style={styles.rowBody}>
                  <Text style={styles.name}>{item.plantName}</Text>
                  <Text style={styles.meta}>{item.date.slice(5)} · {item.location}</Text>
                </View>
              </TouchableOpacity>
            ))}
          </View>
        ))}
        {groups.length === 0 && (
          <View style={styles.empty}>
            <Text style={styles.emptyIcon}>📅</Text>
            <Text style={styles.emptyText}>还没有观察记录</Text>
            <Text style={styles.emptyHint}>去首页新增第一条观察吧</Text>
          </View>
        )}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  title: {fontSize: 24, fontWeight: '700', color: colors.text, paddingHorizontal: 24},
  sub: {fontSize: 13, color: colors.textMuted, paddingHorizontal: 24, marginTop: 4, marginBottom: 8},
  section: {marginBottom: 20},
  monthRow: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10},
  month: {fontSize: 16, fontWeight: '700', color: colors.primary},
  count: {fontSize: 12, color: colors.textMuted},
  row: {
    flexDirection: 'row',
    gap: 12,
    backgroundColor: colors.card,
    borderRadius: 12,
    padding: 10,
    marginBottom: 8,
  },
  rowBody: {flex: 1, justifyContent: 'center'},
  name: {fontSize: 15, fontWeight: '600', color: colors.text},
  meta: {fontSize: 12, color: colors.textSecondary, marginTop: 2},
  empty: {alignItems: 'center', paddingVertical: 80},
  emptyIcon: {fontSize: 40, marginBottom: 12},
  emptyText: {fontSize: 16, fontWeight: '600', color: colors.text},
  emptyHint: {fontSize: 13, color: colors.textMuted, marginTop: 6},
});
