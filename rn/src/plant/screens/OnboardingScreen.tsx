import React from 'react';
import {View, Text, TouchableOpacity, StyleSheet, Dimensions} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import LinearGradient from 'react-native-linear-gradient';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {colors} from '../theme';
import {setOnboardingDone} from '../storage';

const {width} = Dimensions.get('window');

const SLIDES = [
  {
    icon: 'leaf-outline' as const,
    title: '观叶志',
    body: '一款完全离线的植物观察笔记。记录你身边的每一片叶，无需登录，数据仅存本机。',
  },
  {
    icon: 'camera-outline' as const,
    title: '随手记录',
    body: '拍照、写笔记、标记地点与季节。图鉴自动汇总你观察过的每一种植物。',
  },
  {
    icon: 'book-outline' as const,
    title: '离线图志',
    body: '内置常见植物参考信息，仅供观察辅助。从图志一键新建观察，快速上手。',
  },
];

export default function OnboardingScreen({onDone}: {onDone: () => void}) {
  const insets = useSafeAreaInsets();
  const [step, setStep] = React.useState(0);
  const slide = SLIDES[step];
  const isLast = step === SLIDES.length - 1;

  const finish = async () => {
    await setOnboardingDone();
    onDone();
  };

  const next = () => {
    if (isLast) finish();
    else setStep(s => s + 1);
  };

  return (
    <View style={[styles.container, {paddingTop: insets.top + 20, paddingBottom: insets.bottom + 24}]}>
      <LinearGradient colors={['#5A8F6A', '#2F5233']} style={styles.hero}>
        <Ionicons name={slide.icon} size={56} color="#fff" />
      </LinearGradient>
      <Text style={styles.title}>{slide.title}</Text>
      <Text style={styles.body}>{slide.body}</Text>
      <View style={styles.dots}>
        {SLIDES.map((_, i) => (
          <View key={i} style={[styles.dot, i === step && styles.dotActive]} />
        ))}
      </View>
      <TouchableOpacity style={styles.btn} onPress={next} activeOpacity={0.85}>
        <Text style={styles.btnText}>{isLast ? '开始使用' : '下一步'}</Text>
      </TouchableOpacity>
      {!isLast && (
        <TouchableOpacity onPress={finish} style={styles.skip}>
          <Text style={styles.skipText}>跳过</Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
    alignItems: 'center',
    paddingHorizontal: 32,
  },
  hero: {
    width: width * 0.36,
    height: width * 0.36,
    borderRadius: width * 0.18,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 40,
    marginBottom: 36,
  },
  title: {fontSize: 26, fontWeight: '700', color: colors.text, marginBottom: 16},
  body: {fontSize: 16, lineHeight: 26, color: colors.textSecondary, textAlign: 'center'},
  dots: {flexDirection: 'row', gap: 8, marginTop: 40, marginBottom: 32},
  dot: {width: 8, height: 8, borderRadius: 4, backgroundColor: colors.accentSoft},
  dotActive: {backgroundColor: colors.primaryLight, width: 20},
  btn: {
    width: '100%',
    backgroundColor: colors.primaryLight,
    paddingVertical: 15,
    borderRadius: 14,
    alignItems: 'center',
  },
  btnText: {color: '#fff', fontSize: 16, fontWeight: '600'},
  skip: {marginTop: 16, padding: 8},
  skipText: {fontSize: 14, color: colors.textMuted},
});
