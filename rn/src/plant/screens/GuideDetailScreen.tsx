import React from 'react';
import {View, Text, ScrollView, TouchableOpacity, StyleSheet, Image} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {colors} from '../theme';
import {getReferenceById} from '../data/referencePlants';
import {PLANT_IMAGES} from '../assets/images';

export default function GuideDetailScreen({route, navigation}: {route: any; navigation: any}) {
  const insets = useSafeAreaInsets();
  const plant = getReferenceById(route.params.id);
  if (!plant) return null;

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}}>
        <Image source={PLANT_IMAGES[plant.imageAsset]} style={styles.heroImg} />
        <Text style={styles.name}>{plant.name}</Text>
        <Text style={styles.latin}>{plant.latin}</Text>
        <View style={styles.infoRow}>
          <Info label="科属" value={plant.family} />
          <Info label="物候" value={plant.bloom} />
        </View>
        <View style={styles.infoRow}>
          <Info label="常见生境" value={plant.habitat.join('、')} />
        </View>
        <Text style={styles.section}>识别要点</Text>
        <View style={styles.traitRow}>
          {plant.traits.map(t => (
            <View key={t} style={styles.trait}><Text style={styles.traitText}>{t}</Text></View>
          ))}
        </View>
        <Text style={styles.section}>观察提示</Text>
        <Text style={styles.body}>{plant.note}</Text>
        <Text style={styles.disclaimer}>
          以上内容仅供自然观察参考，不构成专业鉴定或学术结论。请以现场形态与权威资料为准。
        </Text>
        <TouchableOpacity
          style={styles.logBtn}
          onPress={() => navigation.navigate('Log', {plantName: plant.name, referenceId: plant.id})}>
          <Text style={styles.logBtnText}>以此植物新建观察</Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

function Info({label, value}: {label: string; value: string}) {
  return (
    <View style={styles.infoCard}>
      <Text style={styles.infoLabel}>{label}</Text>
      <Text style={styles.infoValue}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  heroImg: {width: '100%', height: 200, borderRadius: 16, marginBottom: 16},
  name: {fontSize: 28, fontWeight: '700', color: colors.text},
  latin: {fontSize: 14, color: colors.textMuted, fontStyle: 'italic', marginTop: 4},
  infoRow: {flexDirection: 'row', gap: 10, marginTop: 16},
  infoCard: {
    flex: 1,
    backgroundColor: colors.card,
    borderRadius: 12,
    padding: 12,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  infoLabel: {fontSize: 11, color: colors.textMuted},
  infoValue: {fontSize: 14, color: colors.text, marginTop: 4, fontWeight: '600'},
  section: {fontSize: 16, fontWeight: '700', color: colors.text, marginTop: 24, marginBottom: 10},
  traitRow: {flexDirection: 'row', flexWrap: 'wrap', gap: 8},
  trait: {backgroundColor: colors.accentSoft + '60', paddingHorizontal: 12, paddingVertical: 5, borderRadius: 12},
  traitText: {fontSize: 13, color: colors.primaryLight},
  body: {fontSize: 15, lineHeight: 24, color: colors.text},
  disclaimer: {fontSize: 12, lineHeight: 18, color: colors.textMuted, marginTop: 20},
  logBtn: {
    marginTop: 24,
    backgroundColor: colors.primaryLight,
    paddingVertical: 14,
    borderRadius: 14,
    alignItems: 'center',
  },
  logBtnText: {color: '#fff', fontSize: 16, fontWeight: '600'},
});
