import React from 'react';
import {View, Text, ScrollView, TouchableOpacity, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {colors} from '../theme';

const SECTIONS = [
  {
    title: '一、信息收集',
    body: '观叶志仅在本地存储您主动填写的植物观察记录（名称、地点、季节、生境、笔记与可选照片）。我们不会收集您的真实姓名、手机号、精确位置坐标或其他个人身份信息。您从相册选择的照片仅保存在本机，不会上传。',
  },
  {
    title: '二、信息使用',
    body: '您的观察数据仅用于在本设备上展示个人图鉴与统计。该信息不会上传到任何服务器，也不会用于广告定向。',
  },
  {
    title: '三、信息存储',
    body: '所有记录通过设备本地存储保存。卸载应用后相关数据将被自动清除。您可在「数据管理」中重置演示数据。',
  },
  {
    title: '四、第三方服务',
    body: '本应用不接入第三方广告 SDK 或数据分析平台，不与任何第三方共享您的个人信息。',
  },
  {
    title: '五、免责声明',
    body: '应用内植物参考信息仅供自然观察辅助，不构成专业鉴定或学术结论。观察结果请以实际现场与权威资料为准。',
  },
  {
    title: '六、联系我们',
    body: '如对本政策有疑问，请通过应用内「意见反馈」与我们联系。',
  },
];

export default function PrivacyScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}}>
        <Text style={styles.title}>隐私政策</Text>
        {SECTIONS.map(s => (
          <View key={s.title} style={styles.section}>
            <Text style={styles.sectionTitle}>{s.title}</Text>
            <Text style={styles.body}>{s.body}</Text>
          </View>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginBottom: 16},
  section: {marginBottom: 18},
  sectionTitle: {fontSize: 15, fontWeight: '700', color: colors.text, marginBottom: 6},
  body: {fontSize: 14, lineHeight: 22, color: colors.textSecondary},
});
