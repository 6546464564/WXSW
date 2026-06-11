import React from 'react';
import {View, Text, ScrollView, TouchableOpacity, StyleSheet} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {colors} from '../theme';

const SECTIONS = [
  {
    title: '一、服务说明',
    body: '观叶志是一款离线植物观察笔记工具，帮助用户记录野外或日常环境中的植物发现，整理个人图鉴。本应用无需注册登录，所有数据保存在本机。',
  },
  {
    title: '二、使用规范',
    body: '您应合法、文明地使用本应用。请勿利用本应用发布违法信息。应用内参考内容仅供学习辅助，不替代专业植物鉴定或教学。',
  },
  {
    title: '三、知识产权',
    body: '应用内界面设计与原创参考文案归开发者所有。用户自行创建的观察笔记内容归用户所有。',
  },
  {
    title: '四、免责声明',
    body: '因设备故障、误删或卸载导致的数据丢失，开发者不承担责任。植物识别与观察结论由用户自行判断。',
  },
  {
    title: '五、协议更新',
    body: '我们可能更新本协议，继续使用即视为同意更新后的条款。',
  },
];

export default function TermsScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();
  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}}>
        <Text style={styles.title}>用户协议</Text>
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
