/**
 * 万象书屋 RN · 下载中心
 * 对齐 iOS: DownloadCenterView.swift
 * 显示所有下载任务的进度、取消、重试
 */

import React, {useState, useEffect} from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  SafeAreaView,
} from 'react-native';
import {useThemeColors, Spacing, FontSize, Radius} from '../../app/theme';
import {bookDownloader, DownloadJob} from '../../utils/bookDownloader';

export default function DownloadCenterScreen() {
  const colors = useThemeColors();
  const [jobs, setJobs] = useState<DownloadJob[]>([]);

  useEffect(() => {
    setJobs(bookDownloader.getAllJobs());
    const unsub = bookDownloader.subscribe(() => {
      setJobs(bookDownloader.getAllJobs());
    });
    return unsub;
  }, []);

  const progress = (job: DownloadJob) =>
    job.total > 0 ? (job.completed + job.failed) / job.total : 0;

  const statusText = (job: DownloadJob) => {
    switch (job.status) {
      case 'running':
        return `下载中 ${job.completed + job.failed}/${job.total}`;
      case 'finished':
        return job.failed > 0
          ? `已完成 (${job.failed} 章失败)`
          : '已完成';
      case 'error':
        return '下载失败';
      case 'cancelled':
        return '已取消';
      default:
        return '等待中';
    }
  };

  const statusColor = (job: DownloadJob) => {
    switch (job.status) {
      case 'running':
        return colors.primary;
      case 'finished':
        return '#27ae60';
      case 'error':
      case 'cancelled':
        return '#e67e22';
      default:
        return colors.textSecondary;
    }
  };

  return (
    <SafeAreaView style={[styles.container, {backgroundColor: colors.background}]}>
      {jobs.length === 0 ? (
        <View style={styles.empty}>
          <Text style={[styles.emptyText, {color: colors.textSecondary}]}>
            暂无下载任务
          </Text>
          <Text style={[styles.emptyHint, {color: colors.textSecondary}]}>
            在书籍详情页点击「下载本书」开始下载
          </Text>
        </View>
      ) : (
        <FlatList
          data={jobs}
          keyExtractor={item => item.bookUrl}
          contentContainerStyle={styles.listContent}
          renderItem={({item}) => (
            <View style={[styles.card, {backgroundColor: colors.card}]}>
              <View style={styles.cardHeader}>
                <Text
                  style={[styles.bookName, {color: colors.textPrimary}]}
                  numberOfLines={1}>
                  {item.bookName}
                </Text>
                <Text style={[styles.statusText, {color: statusColor(item)}]}>
                  {statusText(item)}
                </Text>
              </View>

              {item.status === 'running' && (
                <View style={styles.progressWrap}>
                  <View style={[styles.progressBg, {backgroundColor: colors.divider}]}>
                    <View
                      style={[
                        styles.progressFill,
                        {
                          width: `${progress(item) * 100}%`,
                          backgroundColor: colors.primary,
                        },
                      ]}
                    />
                  </View>
                  <Text style={[styles.percentText, {color: colors.textSecondary}]}>
                    {Math.round(progress(item) * 100)}%
                  </Text>
                </View>
              )}

              <View style={styles.cardFooter}>
                <Text style={[styles.rangeText, {color: colors.textSecondary}]}>
                  第 {item.startIdx + 1}–{item.endIdx} 章
                </Text>
                <View style={styles.actions}>
                  {item.status === 'running' && (
                    <TouchableOpacity
                      onPress={() => bookDownloader.cancel(item.bookUrl)}>
                      <Text style={styles.cancelText}>取消</Text>
                    </TouchableOpacity>
                  )}
                </View>
              </View>
            </View>
          )}
        />
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1},
  empty: {flex: 1, justifyContent: 'center', alignItems: 'center', gap: 8},
  emptyText: {fontSize: FontSize.md},
  emptyHint: {fontSize: 12, opacity: 0.7},
  listContent: {padding: Spacing.md, gap: 12},
  card: {
    borderRadius: Radius.md,
    padding: 14,
    gap: 8,
  },
  cardHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  bookName: {fontSize: FontSize.md, fontWeight: '600', flex: 1},
  statusText: {fontSize: 12, fontWeight: '500', marginLeft: 8},
  progressWrap: {flexDirection: 'row', alignItems: 'center', gap: 8},
  progressBg: {flex: 1, height: 4, borderRadius: 2, overflow: 'hidden'},
  progressFill: {height: 4, borderRadius: 2},
  percentText: {fontSize: 11, width: 36, textAlign: 'right'},
  cardFooter: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  rangeText: {fontSize: 11},
  actions: {flexDirection: 'row', gap: 12},
  cancelText: {fontSize: 12, color: '#e67e22', fontWeight: '500'},
});
