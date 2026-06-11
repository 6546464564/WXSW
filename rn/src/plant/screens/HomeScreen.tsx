import React, {useCallback, useState} from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import LinearGradient from 'react-native-linear-gradient';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {colors, cardShadow} from '../theme';
import {loadObservations, uniquePlantCount, thisMonthCount} from '../storage';
import {getSeasonTip} from '../data/seasonTips';
import type {Observation} from '../types';
import PlantThumb from '../components/PlantThumb';
import ScreenShell from '../components/ScreenShell';
import {useLayout} from '../hooks/useLayout';

export default function HomeScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  const {isWide, columns, padX} = useLayout();
  const [list, setList] = useState<Observation[]>([]);
  const cardWidth = columns >= 3 ? '31.5%' : isWide ? '48.5%' : '100%';
  const tip = getSeasonTip();

  useFocusEffect(
    useCallback(() => {
      loadObservations().then(setList);
    }, []),
  );

  const today = new Date();
  const dateStr = `${today.getFullYear()}年${today.getMonth() + 1}月${today.getDate()}日`;

  return (
    <ScreenShell>
      <ScrollView
        contentContainerStyle={{paddingBottom: insets.bottom + 100}}
        showsVerticalScrollIndicator={false}>
        <View style={[styles.banner, {paddingTop: insets.top + 20, paddingHorizontal: padX + 4}]}>
          <LinearGradient
            colors={['#5A8F6A', '#2F5233']}
            start={{x: 0, y: 0}}
            end={{x: 1, y: 1}}
            style={StyleSheet.absoluteFill}
          />
          <Text style={styles.bannerTitle}>观叶志</Text>
          <Text style={styles.bannerSub}>记录身边的每一片叶</Text>
          <Text style={styles.bannerDate}>{dateStr}</Text>
        </View>

        <View style={{paddingHorizontal: padX}}>
          <View style={styles.statsRow}>
            {[
              {val: String(list.length), label: '观察记录'},
              {val: String(uniquePlantCount(list)), label: '收录种类'},
              {val: String(thisMonthCount(list)), label: '本月新增'},
            ].map(s => (
              <View key={s.label} style={[styles.statCard, cardShadow]}>
                <Text style={styles.statVal}>{s.val}</Text>
                <Text style={styles.statLabel}>{s.label}</Text>
              </View>
            ))}
          </View>

          <View style={[styles.tipCard, cardShadow]}>
            <View style={styles.tipHeader}>
              <Ionicons name="sunny-outline" size={18} color={colors.primaryLight} />
              <Text style={styles.tipTitle}>{tip.title}</Text>
            </View>
            <Text style={styles.tipBody}>{tip.body}</Text>
            <Text style={styles.tipPlants}>推荐观察：{tip.plants.join('、')}</Text>
          </View>

          <View style={styles.btnRow}>
            <TouchableOpacity style={[styles.addBtn, cardShadow, styles.btnHalf]} activeOpacity={0.85} onPress={() => navigation.navigate('Log')}>
              <Ionicons name="add" size={20} color="#fff" />
              <Text style={styles.addBtnText}>新增观察</Text>
            </TouchableOpacity>
            <TouchableOpacity style={[styles.calBtn, cardShadow, styles.btnHalf]} activeOpacity={0.85} onPress={() => navigation.navigate('Calendar')}>
              <Ionicons name="calendar-outline" size={20} color={colors.primaryLight} />
              <Text style={styles.calBtnText}>观察日历</Text>
            </TouchableOpacity>
          </View>

          <View style={styles.sectionRow}>
            <Text style={styles.sectionTitle}>最近观察</Text>
            {list.length > 6 && (
              <TouchableOpacity onPress={() => navigation.getParent()?.navigate('AtlasTab')}>
                <Text style={styles.viewAll}>查看全部 ›</Text>
              </TouchableOpacity>
            )}
          </View>
          {list.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyIcon}>🌱</Text>
              <Text style={styles.emptyText}>还没有观察记录</Text>
              <Text style={styles.emptyHint}>点击上方按钮，开始你的第一次观察</Text>
            </View>
          ) : (
            <View style={[styles.listGrid, isWide && styles.listGridWide]}>
              {list.slice(0, 6).map(item => (
                <TouchableOpacity
                  key={item.id}
                  style={[styles.card, cardShadow, isWide && {width: cardWidth}]}
                  activeOpacity={0.75}
                  onPress={() => navigation.navigate('ObservationDetail', {id: item.id})}>
                  <PlantThumb item={item} size={72} />
                  <View style={styles.cardBody}>
                    <View style={styles.cardTop}>
                      <Text style={styles.plantName}>{item.plantName}</Text>
                      <Text style={styles.cardDate}>{item.date}</Text>
                    </View>
                    <Text style={styles.cardLoc}>{item.location} · {item.habitat}</Text>
                    <Text style={styles.cardNote} numberOfLines={2}>{item.note}</Text>
                    <View style={styles.tag}><Text style={styles.tagText}>{item.season}</Text></View>
                  </View>
                </TouchableOpacity>
              ))}
            </View>
          )}
        </View>
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  banner: {
    paddingBottom: 36,
    borderBottomLeftRadius: 24,
    borderBottomRightRadius: 24,
    minHeight: 180,
    overflow: 'hidden',
  },
  bannerTitle: {fontSize: 26, fontWeight: '700', color: '#fff'},
  bannerSub: {fontSize: 14, color: 'rgba(255,255,255,0.85)', marginTop: 6},
  bannerDate: {fontSize: 13, color: 'rgba(255,255,255,0.65)', marginTop: 10},
  statsRow: {flexDirection: 'row', gap: 10, marginTop: -18},
  statCard: {
    flex: 1,
    backgroundColor: colors.card,
    borderRadius: 14,
    paddingVertical: 14,
    alignItems: 'center',
  },
  statVal: {fontSize: 20, fontWeight: '700', color: colors.primary},
  statLabel: {fontSize: 11, color: colors.textMuted, marginTop: 3},
  tipCard: {
    backgroundColor: colors.card,
    borderRadius: 14,
    padding: 14,
    marginTop: 14,
    borderLeftWidth: 3,
    borderLeftColor: colors.primaryLight,
  },
  tipHeader: {flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 6},
  tipTitle: {fontSize: 14, fontWeight: '700', color: colors.primary},
  tipBody: {fontSize: 13, lineHeight: 20, color: colors.textSecondary},
  tipPlants: {fontSize: 12, color: colors.primaryLight, marginTop: 8, fontWeight: '600'},
  btnRow: {flexDirection: 'row', gap: 10, marginTop: 14, marginBottom: 8},
  btnHalf: {flex: 1},
  addBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    backgroundColor: colors.primaryLight,
    paddingVertical: 13,
    borderRadius: 12,
  },
  addBtnText: {color: '#fff', fontSize: 15, fontWeight: '600'},
  calBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    backgroundColor: colors.card,
    paddingVertical: 13,
    borderRadius: 12,
  },
  calBtnText: {color: colors.primaryLight, fontSize: 15, fontWeight: '600'},
  sectionRow: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 16, marginBottom: 10},
  sectionTitle: {fontSize: 16, fontWeight: '700', color: colors.text},
  viewAll: {fontSize: 13, color: colors.primaryLight, fontWeight: '600'},
  listGrid: {gap: 12},
  listGridWide: {flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between'},
  card: {
    flexDirection: 'row',
    gap: 14,
    backgroundColor: colors.card,
    borderRadius: 16,
    padding: 14,
  },
  cardBody: {flex: 1},
  cardTop: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start'},
  plantName: {fontSize: 16, fontWeight: '700', color: colors.text, flex: 1},
  cardDate: {fontSize: 11, color: colors.textMuted, marginLeft: 8},
  cardLoc: {fontSize: 12, color: colors.textSecondary, marginTop: 4},
  cardNote: {fontSize: 13, color: colors.text, lineHeight: 20, marginTop: 6},
  tag: {
    alignSelf: 'flex-start',
    backgroundColor: colors.accentSoft,
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 8,
    marginTop: 8,
  },
  tagText: {fontSize: 10, color: colors.primaryLight, fontWeight: '600'},
  empty: {alignItems: 'center', paddingVertical: 40, backgroundColor: colors.card, borderRadius: 16},
  emptyIcon: {fontSize: 36, marginBottom: 10},
  emptyText: {fontSize: 15, fontWeight: '600', color: colors.text},
  emptyHint: {fontSize: 13, color: colors.textMuted, marginTop: 6},
});
