import React, {useEffect, useState} from 'react';
import {View, Text, ScrollView, TouchableOpacity, StyleSheet, Alert, Image, Share} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {colors, cardShadow} from '../theme';
import {deleteObservation, loadObservations} from '../storage';
import {getReferenceById} from '../data/referencePlants';
import {resolveImageSource} from '../assets/images';
import type {Observation} from '../types';

export default function ObservationDetailScreen({route, navigation}: {route: any; navigation: any}) {
  const insets = useSafeAreaInsets();
  const [item, setItem] = useState<Observation | null>(null);

  useEffect(() => {
    loadObservations().then(list => {
      setItem(list.find(o => o.id === route.params.id) || null);
    });
  }, [route.params.id]);

  if (!item) return null;
  const ref = item.referenceId ? getReferenceById(item.referenceId) : null;
  const img = resolveImageSource(item);

  const handleDelete = () => {
    Alert.alert('删除记录', '确定删除这条观察吗？', [
      {text: '取消', style: 'cancel'},
      {
        text: '删除',
        style: 'destructive',
        onPress: async () => {
          await deleteObservation(item.id);
          navigation.goBack();
        },
      },
    ]);
  };

  const handleShare = async () => {
    const lines = [
      `【观叶志】${item.plantName}`,
      `日期：${item.date}`,
      `地点：${item.location}（${item.habitat}）`,
      `季节：${item.season}`,
      `笔记：${item.note}`,
    ];
    if (ref) lines.push(`参考：${ref.latin}`);
    try {
      await Share.share({message: lines.join('\n')});
    } catch {}
  };

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <View style={styles.topBar}>
        <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
          <Text style={styles.backText}>‹ 返回</Text>
        </TouchableOpacity>
        <View style={styles.actions}>
          <TouchableOpacity style={styles.iconBtn} onPress={handleShare}>
            <Ionicons name="share-outline" size={22} color={colors.primaryLight} />
          </TouchableOpacity>
          <TouchableOpacity style={styles.iconBtn} onPress={() => navigation.navigate('Log', {editId: item.id})}>
            <Ionicons name="create-outline" size={22} color={colors.primaryLight} />
          </TouchableOpacity>
        </View>
      </View>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}}>
        {img ? <Image source={img} style={styles.heroImg} /> : (
          <View style={styles.noImg}><Ionicons name="leaf-outline" size={40} color={colors.accent} /></View>
        )}
        <Text style={styles.name}>{item.plantName}</Text>
        {ref && <Text style={styles.latin}>{ref.latin}</Text>}
        <View style={[styles.metaCard, cardShadow]}>
          <Meta label="日期" value={item.date} />
          <Meta label="地点" value={item.location} />
          <Meta label="生境" value={item.habitat} />
          <Meta label="季节" value={item.season} />
        </View>
        <Text style={styles.section}>观察笔记</Text>
        <View style={[styles.noteCard, cardShadow]}>
          <Text style={styles.body}>{item.note}</Text>
        </View>
        {ref && (
          <>
            <Text style={styles.section}>参考信息</Text>
            <Text style={styles.refBody}>{ref.note}</Text>
          </>
        )}
        <TouchableOpacity style={styles.delBtn} onPress={handleDelete}>
          <Text style={styles.delText}>删除此记录</Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

function Meta({label, value}: {label: string; value: string}) {
  return (
    <View style={styles.metaRow}>
      <Text style={styles.metaLabel}>{label}</Text>
      <Text style={styles.metaValue}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  topBar: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingRight: 12},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  actions: {flexDirection: 'row', gap: 4},
  iconBtn: {padding: 8},
  heroImg: {width: '100%', height: 220, borderRadius: 16, marginBottom: 16},
  noImg: {
    width: '100%',
    height: 120,
    borderRadius: 16,
    backgroundColor: colors.accentSoft + '80',
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 16,
  },
  name: {fontSize: 28, fontWeight: '700', color: colors.text},
  latin: {fontSize: 14, color: colors.textMuted, fontStyle: 'italic', marginTop: 4},
  metaCard: {
    backgroundColor: colors.card,
    borderRadius: 14,
    padding: 16,
    marginTop: 16,
  },
  metaRow: {flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 6},
  metaLabel: {fontSize: 14, color: colors.textMuted},
  metaValue: {fontSize: 14, color: colors.text, fontWeight: '600'},
  section: {fontSize: 16, fontWeight: '700', color: colors.text, marginTop: 24, marginBottom: 10},
  noteCard: {backgroundColor: colors.card, borderRadius: 14, padding: 16},
  body: {fontSize: 15, lineHeight: 24, color: colors.text},
  refBody: {fontSize: 14, lineHeight: 22, color: colors.textSecondary},
  delBtn: {marginTop: 32, alignItems: 'center', paddingVertical: 12},
  delText: {fontSize: 15, color: '#C45C5C'},
});
