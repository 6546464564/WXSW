import React from 'react';
import {View, Text, TouchableOpacity, ScrollView, StyleSheet, Alert} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {colors, cardShadow} from '../theme';

export default function SettingsScreen({navigation}: {navigation: any}) {
  const insets = useSafeAreaInsets();

  const resetDemo = () => {
    Alert.alert('重置演示数据', '将恢复内置示例观察记录，自定义记录会被清除。', [
      {text: '取消', style: 'cancel'},
      {
        text: '重置',
        style: 'destructive',
        onPress: async () => {
          await AsyncStorage.removeItem('guanzhi.observations');
          await AsyncStorage.removeItem('guanzhi.seeded.v2');
          Alert.alert('已重置', '请返回首页查看演示数据');
        },
      },
    ]);
  };

  const clearAll = () => {
    Alert.alert('清空所有记录', '此操作不可撤销，将删除您的全部观察记录。', [
      {text: '取消', style: 'cancel'},
      {
        text: '清空',
        style: 'destructive',
        onPress: async () => {
          await AsyncStorage.setItem('guanzhi.observations', '[]');
          await AsyncStorage.setItem('guanzhi.seeded.v2', '1');
          Alert.alert('已清空', '所有观察记录已删除');
        },
      },
    ]);
  };

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 返回</Text>
      </TouchableOpacity>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}}>
        <Text style={styles.title}>数据管理</Text>
        <Text style={styles.body}>
          观叶志所有观察记录均保存在本机，不会上传云端。卸载应用后数据将被清除。
        </Text>

        <View style={[styles.section, cardShadow]}>
          <TouchableOpacity style={styles.row} onPress={resetDemo}>
            <View style={styles.rowBody}>
              <Text style={styles.rowLabel}>恢复演示数据</Text>
              <Text style={styles.rowSub}>清除现有记录，恢复 4 条内置示例</Text>
            </View>
            <Text style={styles.arrow}>›</Text>
          </TouchableOpacity>
          <View style={styles.divider} />
          <TouchableOpacity style={styles.row} onPress={clearAll}>
            <View style={styles.rowBody}>
              <Text style={[styles.rowLabel, {color: '#C45C5C'}]}>清空所有记录</Text>
              <Text style={styles.rowSub}>删除全部观察数据，此操作不可撤销</Text>
            </View>
            <Text style={styles.arrow}>›</Text>
          </TouchableOpacity>
        </View>

        <Text style={styles.sectionTitle}>关于</Text>
        <View style={[styles.section, cardShadow]}>
          <View style={styles.aboutRow}>
            <Text style={styles.aboutLabel}>应用名称</Text>
            <Text style={styles.aboutValue}>观叶志</Text>
          </View>
          <View style={styles.divider} />
          <View style={styles.aboutRow}>
            <Text style={styles.aboutLabel}>版本</Text>
            <Text style={styles.aboutValue}>1.0.0</Text>
          </View>
          <View style={styles.divider} />
          <View style={styles.aboutRow}>
            <Text style={styles.aboutLabel}>数据存储</Text>
            <Text style={styles.aboutValue}>仅限本机</Text>
          </View>
          <View style={styles.divider} />
          <View style={styles.aboutRow}>
            <Text style={styles.aboutLabel}>网络访问</Text>
            <Text style={styles.aboutValue}>不需要</Text>
          </View>
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginBottom: 12},
  body: {fontSize: 15, lineHeight: 22, color: colors.textSecondary, marginBottom: 20},
  sectionTitle: {fontSize: 16, fontWeight: '700', color: colors.text, marginTop: 24, marginBottom: 10},
  section: {
    backgroundColor: colors.card,
    borderRadius: 14,
    overflow: 'hidden',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 14,
    paddingHorizontal: 16,
  },
  rowBody: {flex: 1},
  rowLabel: {fontSize: 15, color: colors.text, fontWeight: '500'},
  rowSub: {fontSize: 12, color: colors.textMuted, marginTop: 2},
  arrow: {fontSize: 20, color: colors.textMuted},
  divider: {height: StyleSheet.hairlineWidth, backgroundColor: colors.border, marginHorizontal: 16},
  aboutRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 13,
    paddingHorizontal: 16,
  },
  aboutLabel: {fontSize: 14, color: colors.textSecondary},
  aboutValue: {fontSize: 14, color: colors.text, fontWeight: '500'},
});
