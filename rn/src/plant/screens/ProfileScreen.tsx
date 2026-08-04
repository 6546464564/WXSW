import React, {useCallback, useState} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  Share,
  Linking,
} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {useFocusEffect} from '@react-navigation/native';
import LinearGradient from 'react-native-linear-gradient';
import Ionicons from 'react-native-vector-icons/Ionicons';
import ScreenShell from '../components/ScreenShell';
import {useLayout} from '../hooks/useLayout';
import {colors, cardShadow} from '../theme';
import {loadObservations, uniquePlantCount} from '../storage';


export default function ProfileScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  const {padX, isWide} = useLayout();
  const [count, setCount] = useState(0);
  const [species, setSpecies] = useState(0);

  useFocusEffect(
    useCallback(() => {
      loadObservations().then(list => {
        setCount(list.length);
        setSpecies(uniquePlantCount(list));
      });
    }, []),
  );

  const handleShare = async () => {
    try {
      await Share.share({message: '观叶志 — 离线植物观察笔记，记录身边的每一片叶。'});
    } catch {}
  };

  const handleFeedback = () => {
    Linking.openURL('mailto:feedback@wxsw.app?subject=观叶志反馈').catch(() => {});
  };

  const menuItems = [
    {icon: 'leaf-outline' as const, label: '数据管理', sub: '清空或导出（本地）', onPress: () => navigation.navigate('Settings')},
    {icon: 'share-outline' as const, label: '分享给朋友', sub: '推荐观叶志', onPress: handleShare},
    {icon: 'chatbubble-outline' as const, label: '意见反馈', sub: '帮助我们改进', onPress: handleFeedback},
    {icon: 'document-text-outline' as const, label: '隐私政策', sub: '', onPress: () => navigation.navigate('Privacy')},
    {icon: 'reader-outline' as const, label: '用户协议', sub: '', onPress: () => navigation.navigate('Terms')},
  ];

  return (
    <ScreenShell style={{paddingTop: insets.top}}>
      <ScrollView contentContainerStyle={{paddingHorizontal: padX, paddingBottom: insets.bottom + 100}}>
        <Text style={styles.title}>我的</Text>

        <View style={[styles.hero, cardShadow, isWide && styles.heroWide]}>
          <LinearGradient
            colors={['#5A8F6A', '#2F5233']}
            style={StyleSheet.absoluteFill}
          />
          <View style={styles.avatar}>
            <Ionicons name="leaf" size={26} color="#fff" />
          </View>
          <Text style={styles.heroTitle}>观叶志</Text>
          <Text style={styles.heroSub}>记录每一次遇见的绿</Text>
        </View>

        <View style={styles.statsRow}>
          <View style={[styles.stat, cardShadow]}><Text style={styles.statVal}>{count}</Text><Text style={styles.statLabel}>观察记录</Text></View>
          <View style={[styles.stat, cardShadow]}><Text style={styles.statVal}>{species}</Text><Text style={styles.statLabel}>收录种类</Text></View>
        </View>

        <View style={[styles.menu, cardShadow]}>
          {menuItems.map((item, idx) => (
            <TouchableOpacity
              key={item.label}
              style={[styles.menuItem, idx < menuItems.length - 1 && styles.menuDivider]}
              onPress={item.onPress}
              activeOpacity={0.6}>
              <Ionicons name={item.icon} size={22} color={colors.primaryLight} style={styles.menuIcon} />
              <View style={styles.menuBody}>
                <Text style={styles.menuLabel}>{item.label}</Text>
                {item.sub ? <Text style={styles.menuSub}>{item.sub}</Text> : null}
              </View>
              <Text style={styles.arrow}>›</Text>
            </TouchableOpacity>
          ))}
        </View>

        <Text style={styles.footer}>观叶志 · 离线植物观察笔记</Text>
        <Text style={styles.version}>Version 1.0.0</Text>
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginTop: 8, marginBottom: 16},
  hero: {
    borderRadius: 18,
    padding: 22,
    alignItems: 'center',
    marginBottom: 16,
    overflow: 'hidden',
  },
  heroWide: {flexDirection: 'row', gap: 16, justifyContent: 'center'},
  avatar: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: 'rgba(255,255,255,0.2)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  heroTitle: {fontSize: 20, fontWeight: '700', color: '#fff', marginTop: 10},
  heroSub: {fontSize: 13, color: 'rgba(255,255,255,0.8)', marginTop: 4},
  statsRow: {flexDirection: 'row', gap: 12, marginBottom: 20},
  stat: {
    flex: 1,
    backgroundColor: colors.card,
    borderRadius: 14,
    paddingVertical: 14,
    alignItems: 'center',
  },
  statVal: {fontSize: 20, fontWeight: '700', color: colors.primary},
  statLabel: {fontSize: 11, color: colors.textMuted, marginTop: 4},
  menu: {
    backgroundColor: colors.card,
    borderRadius: 16,
    overflow: 'hidden',
  },
  menuItem: {flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: 16},
  menuDivider: {borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border},
  menuIcon: {marginRight: 12},
  menuBody: {flex: 1},
  menuLabel: {fontSize: 15, color: colors.text},
  menuSub: {fontSize: 12, color: colors.textMuted, marginTop: 2},
  arrow: {fontSize: 20, color: colors.textMuted},
  footer: {textAlign: 'center', color: colors.textMuted, fontSize: 13, marginTop: 28},
  version: {textAlign: 'center', color: colors.textMuted, fontSize: 11, marginTop: 4, opacity: 0.7},
});
