/**
 * 万象书屋 RN · 我的
 * 1:1 对齐 iOS: MyView.swift
 * - 分组 List
 * - 主题模式 Picker / 护眼模式 Toggle
 * - 意见反馈 / 下载管理 / 应用伪装 → NavigationLink 样式
 * - 底部版本信息
 */

import React, {useState} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  Switch,
  StyleSheet,
  SafeAreaView,
  Alert,
  Platform,
} from 'react-native';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {Colors, Spacing, FontSize, Radius} from '../../app/theme';

type ThemeMode = 'system' | 'day' | 'night';

function MyRowLabel({
  icon,
  title,
  subtitle,
}: {
  icon: string;
  title: string;
  subtitle?: string;
}) {
  return (
    <View style={styles.rowLabel}>
      <Ionicons name={icon} size={17} color={Colors.primary} style={{width: 26, textAlign: 'center'}} />
      <View style={styles.rowTextCol}>
        <Text style={styles.rowTitle}>{title}</Text>
        {subtitle ? (
          <Text style={styles.rowSubtitle} numberOfLines={2}>
            {subtitle}
          </Text>
        ) : null}
      </View>
    </View>
  );
}

export default function SettingsScreen() {
  const [themeMode, setThemeMode] = useState<ThemeMode>('system');
  const [eyeCare, setEyeCare] = useState(false);

  const themeModeSummary =
    themeMode === 'system'
      ? '跟随系统'
      : themeMode === 'day'
        ? '日间模式'
        : '夜间模式';

  const confirmRelock = () => {
    Alert.alert('确认伪装?', '启用后需要通过水质检测小游戏才能再次解锁', [
      {text: '取消', style: 'cancel'},
      {
        text: '启用伪装',
        style: 'destructive',
        onPress: () => {},
      },
    ]);
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.scrollContent}>
        {/* 标题 — 对齐 iOS .navigationTitle("我的") */}
        <Text style={styles.header}>我的</Text>

        {/* Section 1: 主题 + 护眼 + 反馈 + 下载 + 伪装 */}
        <View style={styles.section}>
          {/* 主题模式 */}
          <View style={styles.row}>
            <MyRowLabel
              icon="contrast-outline"
              title="主题模式"
              subtitle={themeModeSummary}
            />
            <View style={styles.themePicker}>
              {(['system', 'day', 'night'] as ThemeMode[]).map(m => (
                <TouchableOpacity
                  key={m}
                  style={[
                    styles.themeBtn,
                    themeMode === m && styles.themeBtnActive,
                  ]}
                  onPress={() => setThemeMode(m)}>
                  <Text
                    style={[
                      styles.themeText,
                      themeMode === m && styles.themeTextActive,
                    ]}>
                    {m === 'system' ? '跟随' : m === 'day' ? '日间' : '夜间'}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          </View>

          <View style={styles.divider} />

          {/* 护眼模式 */}
          <View style={styles.row}>
            <MyRowLabel
              icon="sunny-outline"
              title="护眼模式"
              subtitle="减少蓝光，保护视力"
            />
            <Switch
              value={eyeCare}
              onValueChange={setEyeCare}
              trackColor={{true: Colors.primary, false: Colors.divider}}
              thumbColor={Platform.OS === 'android' ? Colors.white : undefined}
            />
          </View>

          <View style={styles.divider} />

          {/* 意见反馈 */}
          <TouchableOpacity style={styles.row}>
            <MyRowLabel
              icon="chatbubbles-outline"
              title="意见反馈"
              subtitle="问题反馈和功能建议"
            />
            <Text style={styles.arrow}>›</Text>
          </TouchableOpacity>

          <View style={styles.divider} />

          {/* 下载管理 */}
          <TouchableOpacity style={styles.row}>
            <MyRowLabel
              icon="arrow-down-circle-outline"
              title="下载管理"
              subtitle="无下载任务"
            />
            <Text style={styles.arrow}>›</Text>
          </TouchableOpacity>

          <View style={styles.divider} />

          {/* 应用伪装 */}
          <TouchableOpacity style={styles.row} onPress={confirmRelock}>
            <MyRowLabel
              icon="shield-outline"
              title="应用伪装"
              subtitle="通过小游戏解锁真实界面"
            />
            <Text style={styles.arrow}>›</Text>
          </TouchableOpacity>
        </View>

        {/* Section 2: 版本信息 */}
        <View style={styles.aboutSection}>
          <Text style={styles.aboutText}>
            万象书屋 {Platform.OS === 'ios' ? 'iOS' : 'Android'}
          </Text>
          <Text style={styles.aboutVersion}>v1.0.0 · build 1</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: Colors.background},
  scrollContent: {paddingBottom: 40},
  header: {
    fontSize: FontSize.xl,
    fontWeight: '700',
    color: Colors.textPrimary,
    paddingHorizontal: Spacing.md,
    paddingTop: Spacing.md,
    paddingBottom: Spacing.sm,
    textAlign: 'center',
  },

  // Section
  section: {
    backgroundColor: Colors.card,
    borderRadius: Radius.md,
    marginHorizontal: Spacing.md,
    marginTop: Spacing.md,
    overflow: 'hidden',
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: Colors.divider,
    marginLeft: 52,
  },

  // Row
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingVertical: 14,
  },
  rowLabel: {flex: 1, flexDirection: 'row', alignItems: 'center', gap: 12},
  rowTextCol: {flex: 1},
  rowTitle: {fontSize: FontSize.md, color: Colors.textPrimary},
  rowSubtitle: {fontSize: 12, color: Colors.textSecondary, marginTop: 2},
  arrow: {fontSize: 22, color: Colors.textSecondary, marginLeft: 4},

  // Theme picker
  themePicker: {flexDirection: 'row', gap: 4},
  themeBtn: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: Radius.sm,
    backgroundColor: Colors.background,
  },
  themeBtnActive: {backgroundColor: Colors.primary},
  themeText: {fontSize: 12, color: Colors.textSecondary},
  themeTextActive: {color: Colors.white, fontWeight: '600'},

  // About
  aboutSection: {
    alignItems: 'center',
    paddingVertical: Spacing.xl,
    paddingBottom: 40,
  },
  aboutText: {fontSize: 12, color: Colors.textSecondary},
  aboutVersion: {fontSize: 10, color: Colors.textSecondary, marginTop: 4, opacity: 0.7},
});
