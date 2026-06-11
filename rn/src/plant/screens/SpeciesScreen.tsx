import React, {useCallback, useState} from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import {colors, cardShadow} from '../theme';
import {loadObservations, observationsByPlantName} from '../storage';
import PlantThumb from '../components/PlantThumb';
import type {Observation} from '../types';

export default function SpeciesScreen({route, navigation}: {route: any; navigation: any}) {
  const insets = useSafeAreaInsets();
  const plantName = route.params.plantName as string;
  const [list, setList] = useState<Observation[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadObservations().then(all => setList(observationsByPlantName(all, plantName)));
    }, [plantName]),
  );

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <View style={styles.header}>
        <Text style={styles.title}>{plantName}</Text>
        <Text style={styles.sub}>共 {list.length} 条观察记录</Text>
      </View>
      <ScrollView contentContainerStyle={{padding: 20, paddingBottom: insets.bottom + 40}}>
        {list.map(item => (
          <TouchableOpacity
            key={item.id}
            style={[styles.row, cardShadow]}
            activeOpacity={0.75}
            onPress={() => navigation.navigate('ObservationDetail', {id: item.id})}>
            <PlantThumb item={item} size={56} />
            <View style={styles.rowBody}>
              <Text style={styles.date}>{item.date}</Text>
              <Text style={styles.loc}>{item.location} · {item.habitat}</Text>
              <Text style={styles.note} numberOfLines={2}>{item.note}</Text>
            </View>
          </TouchableOpacity>
        ))}
        {list.length === 0 && (
          <View style={styles.empty}>
            <Text style={styles.emptyText}>暂无记录</Text>
          </View>
        )}
      </ScrollView>
      <TouchableOpacity
        style={[styles.addFab, {bottom: insets.bottom + 20}]}
        onPress={() => navigation.navigate('Log', {plantName})}>
        <Text style={styles.addFabText}>+ 新增观察</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  header: {paddingHorizontal: 24, paddingBottom: 8},
  title: {fontSize: 24, fontWeight: '700', color: colors.text},
  sub: {fontSize: 13, color: colors.textMuted, marginTop: 4},
  row: {
    flexDirection: 'row',
    gap: 12,
    backgroundColor: colors.card,
    borderRadius: 14,
    padding: 12,
    marginBottom: 10,
  },
  rowBody: {flex: 1},
  date: {fontSize: 14, fontWeight: '600', color: colors.text},
  loc: {fontSize: 12, color: colors.textSecondary, marginTop: 2},
  note: {fontSize: 13, color: colors.text, lineHeight: 20, marginTop: 6},
  empty: {alignItems: 'center', paddingVertical: 60},
  emptyText: {fontSize: 14, color: colors.textMuted},
  addFab: {
    position: 'absolute',
    alignSelf: 'center',
    backgroundColor: colors.primaryLight,
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 24,
  },
  addFabText: {color: '#fff', fontSize: 15, fontWeight: '600'},
});
