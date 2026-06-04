/**
 * 万象书屋 RN · 通用封面
 * 对齐 iOS: BookCover.swift
 * - 真 url → Image (含 Referer 头)
 * - 失败 / 无 url → 彩色渐变占位 (书名哈希挑色)
 */

import React, {useState, useEffect} from 'react';
import {View, Text, Image, StyleSheet, ActivityIndicator} from 'react-native';
import LinearGradient from 'react-native-linear-gradient';
import {Colors, CoverPalettes} from '../app/theme';
import {wanxiangClient} from '../api/client';

interface Props {
  url?: string | null;
  width: number;
  height: number;
  bookTitle?: string;
  bookAuthor?: string;
  borderRadius?: number;
}

function hashCode(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

const coverCache = new Map<string, string | null>();

export default function BookCover({
  url,
  width,
  height,
  bookTitle,
  bookAuthor,
  borderRadius = 4,
}: Props) {
  const [failed, setFailed] = useState(false);
  const [loading, setLoading] = useState(!!url);
  const [fallbackUrl, setFallbackUrl] = useState<string | null>(null);

  // 封面加载失败时从起点搜索封面（对齐 iOS QidianBook.lookupQidianCover）
  useEffect(() => {
    if (!failed || !bookTitle?.trim()) return;
    const name = bookTitle.trim();
    const author = bookAuthor?.trim() || '';
    const cacheKey = name + '|' + author;
    if (coverCache.has(cacheKey)) {
      setFallbackUrl(coverCache.get(cacheKey) || null);
      return;
    }
    wanxiangClient.instance
      .get<{ok: boolean; coverUrl: string | null}>('/api/cover', {
        params: {name, author},
        timeout: 8000,
      })
      .then(res => {
        const coverUrl = res.data?.coverUrl || null;
        coverCache.set(cacheKey, coverUrl);
        if (coverUrl) setFallbackUrl(coverUrl);
      })
      .catch(() => {
        coverCache.set(cacheKey, null);
      });
  }, [failed, bookTitle]);

  const trimmedUrl = url?.trim() || '';
  const activeUrl = fallbackUrl || trimmedUrl;
  const showImage = activeUrl.length > 0 && !(failed && !fallbackUrl);

  if (showImage) {
    return (
      <View style={[styles.wrap, {width, height, borderRadius}]}>
        <Image
          source={{
            uri: activeUrl,
            headers: {
              Referer: activeUrl.replace(/(https?:\/\/[^/]+).*/, '$1/'),
              'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
              Accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
            },
          }}
          style={styles.fillImage}
          onLoad={() => setLoading(false)}
          onError={() => {
            if (!fallbackUrl) {
              setFailed(true);
            }
            setLoading(false);
          }}
          resizeMode="cover"
        />
        {loading && (
          <View style={styles.loadingOverlay}>
            <ActivityIndicator size="small" color={Colors.primary} />
          </View>
        )}
      </View>
    );
  }

  const title = bookTitle?.trim() || '';
  if (title.length > 0) {
    const idx = hashCode(title) % CoverPalettes.length;
    const [c1, c2] = CoverPalettes[idx];
    const fontSize = Math.max(12, Math.min(width, height) * 0.32);
    return (
      <LinearGradient
        colors={[c1, c2]}
        start={{x: 0, y: 0}}
        end={{x: 1, y: 1}}
        style={[styles.placeholder, {width, height, borderRadius}]}>
        <Text
          style={[styles.placeholderText, {fontSize}]}
          numberOfLines={2}
          adjustsFontSizeToFit>
          {title.slice(0, 2)}
        </Text>
      </LinearGradient>
    );
  }

  return (
    <View
      style={[
        styles.emptyPlaceholder,
        {width, height, borderRadius},
      ]}>
      <Text style={styles.emptyIcon}>📖</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {overflow: 'hidden', backgroundColor: '#E0D3BC'},
  fillImage: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  },
  loadingOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.05)',
  },
  placeholder: {
    justifyContent: 'center',
    alignItems: 'center',
    overflow: 'hidden',
  },
  placeholderText: {
    color: 'rgba(255,255,255,0.92)',
    fontWeight: 'bold',
    textAlign: 'center',
    paddingHorizontal: 4,
  },
  emptyPlaceholder: {
    backgroundColor: '#E0D3BC',
    justifyContent: 'center',
    alignItems: 'center',
  },
  emptyIcon: {fontSize: 20, opacity: 0.5},
});
