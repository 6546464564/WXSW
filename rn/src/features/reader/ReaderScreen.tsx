/**
 * 万象书屋 RN · 阅读器
 * 对齐 iOS: ReaderView.swift + ReadConfig.swift + ReadStyleSheet.swift
 *
 * 5 种翻页模式 (同 iOS PageAnim):
 *  0 覆盖  cover     — 新页从右滑入覆盖旧页
 *  1 滑动  slide     — 两页一起平移 (标准水平分页)
 *  2 仿真  simulate  — 3D 翻书近似
 *  3 滚动  scroll    — 垂直无限滚动
 *  4 无动画 none     — 瞬间切页
 */

import React, {useEffect, useState, useCallback, useRef, useMemo} from 'react';
import {
  View,
  Text,
  ScrollView,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  StyleSheet,
  Dimensions,
  StatusBar,
  Modal,
  type TextLayoutEventData,
  type NativeSyntheticEvent,
} from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
  interpolate,
  Extrapolation,
  runOnJS,
} from 'react-native-reanimated';
import {Gesture, GestureDetector} from 'react-native-gesture-handler';
import {useRoute, useNavigation, RouteProp} from '@react-navigation/native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {ruleEngine} from '../../engine/RuleEngine';
import {fetchLibraryContent, fetchLibraryChapters} from '../../api/library';
import {fetchProxyToc, fetchProxyContent, prefetchProxyContent, changeSourceSearch} from '../../api/search';
import {useSourceStore} from '../../store/sourceStore';
import {useBookshelfStore} from '../../store/bookshelfStore';
import {useReaderStore, type PageMode} from '../../store/readerStore';
import {Chapter} from '../../engine/types';
import {Colors, Spacing, FontSize, Radius} from '../../app/theme';
import {RootStackParamList} from '../../app/Navigation';

type ReaderRoute = RouteProp<RootStackParamList, 'Reader'>;
const {width: SCREEN_W, height: SCREEN_H} = Dimensions.get('window');
const TAP_ZONE = SCREEN_W / 3;
const SWIPE_THRESHOLD = 50;

const THEMES = [
  {key: 'default', label: '默认', bg: '#F5EFE6', text: '#3E2D1B'},
  {key: 'eye', label: '护眼', bg: '#C7EDCC', text: '#333333'},
  {key: 'night', label: '夜间', bg: '#161616', text: '#9B968C'},
  {key: 'parchment', label: '羊皮', bg: '#EFDFB6', text: '#4A351B'},
] as const;

const PAGE_MODES: {key: PageMode; label: string}[] = [
  {key: 'cover', label: '覆盖'},
  {key: 'slide', label: '滑动'},
  {key: 'simulate', label: '仿真'},
  {key: 'scroll', label: '滚动'},
  {key: 'none', label: '无动画'},
];

function formatTime(): string {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

// ─── 分页 ───
const H_PADDING = 20;
const HEADER_H = 30;
const FOOTER_H = 24;
const TITLE_EXTRA_H = 50;

interface TextLine {
  text: string;
  width: number;
  height: number;
  y: number;
}

/**
 * 根据 onTextLayout 返回的精确行信息分页 (对齐 iOS PaginationEngine)
 * lines 来自原生文本引擎，高度精确到像素。
 */
function paginateByLines(
  lines: TextLine[],
  topInset: number,
  bottomInset: number,
  isFirstChapterPage: boolean,
): string[] {
  if (lines.length === 0) return [''];

  const availH = SCREEN_H - topInset - bottomInset - HEADER_H - FOOTER_H - 24;
  const firstPageH = isFirstChapterPage
    ? Math.max(availH - TITLE_EXTRA_H, availH * 0.5)
    : availH;

  const pages: string[] = [];
  let pageLines: string[] = [];
  let usedH = 0;
  let maxH = firstPageH;

  for (const line of lines) {
    const lh = line.height > 0 ? line.height : 20;
    if (usedH + lh > maxH && pageLines.length > 0) {
      pages.push(pageLines.join(''));
      pageLines = [];
      usedH = 0;
      maxH = availH;
    }
    pageLines.push(line.text);
    usedH += lh;
  }
  if (pageLines.length > 0) {
    pages.push(pageLines.join(''));
  }
  return pages.length > 0 ? pages : [''];
}

/** 估算分页 (onTextLayout 尚未触发时的 fallback) */
function estimatePages(
  text: string,
  fontSize: number,
  lineHeight: number,
  topInset: number,
  bottomInset: number,
): string[] {
  const availH = SCREEN_H - topInset - bottomInset - HEADER_H - FOOTER_H - 24;
  const lineH = fontSize * lineHeight;
  const linesPerPage = Math.max(1, Math.floor(availH / lineH));
  const charsPerLine = Math.max(1, Math.floor((SCREEN_W - 2 * H_PADDING) / fontSize));
  const charsPerPage = linesPerPage * charsPerLine;

  if (text.length <= charsPerPage) return [text];

  const pages: string[] = [];
  let pos = 0;
  while (pos < text.length) {
    pages.push(text.slice(pos, pos + charsPerPage));
    pos += charsPerPage;
  }
  return pages;
}

// ─── 横向翻页阅读器 (cover / slide / simulate / none) ───

interface PagedReaderProps {
  pages: string[];
  pageIndex: number;
  onPageChange: (idx: number) => void;
  onTapCenter: () => void;
  fontSize: number;
  lineHeight: number;
  textColor: string;
  bgColor: string;
  chapterTitle: string;
  bookName: string;
  timeStr: string;
  progress: string;
  pageMode: PageMode;
  topInset: number;
  bottomInset: number;
  onPrevChapter: () => void;
  onNextChapter: () => void;
  hasPrevChapter: boolean;
  hasNextChapter: boolean;
  totalChapters: number;
  currentChapterIdx: number;
}

function PagedReader({
  pages,
  pageIndex,
  onPageChange,
  onTapCenter,
  fontSize,
  lineHeight: lh,
  textColor,
  bgColor,
  chapterTitle,
  bookName,
  timeStr,
  progress,
  pageMode,
  topInset,
  bottomInset,
  onPrevChapter,
  onNextChapter,
  hasPrevChapter,
  hasNextChapter,
}: PagedReaderProps) {
  const panX = useSharedValue(0);

  const canGoPrev = pageIndex > 0 || hasPrevChapter;
  const canGoNext = pageIndex < pages.length - 1 || hasNextChapter;

  const goForward = useCallback(() => {
    const next = pageIndex + 1;
    if (next < pages.length) onPageChange(next);
    else if (hasNextChapter) onNextChapter();
  }, [pageIndex, pages.length, onPageChange, hasNextChapter, onNextChapter]);

  const goBack = useCallback(() => {
    const prev = pageIndex - 1;
    if (prev >= 0) onPageChange(prev);
    else if (hasPrevChapter) onPrevChapter();
  }, [pageIndex, onPageChange, hasPrevChapter, onPrevChapter]);

  const animDuration = pageMode === 'simulate' ? 350 : 250;

  const panGesture = useMemo(
    () =>
      Gesture.Pan()
        .activeOffsetX([-10, 10])
        .failOffsetY([-15, 15])
        .onUpdate(e => {
          'worklet';
          if (pageMode === 'none') return;
          let dx = e.translationX;
          if (!canGoPrev && dx > 0) dx *= 0.3;
          if (!canGoNext && dx < 0) dx *= 0.3;
          panX.value = dx;
        })
        .onEnd(e => {
          'worklet';
          if (pageMode === 'none') {
            if (Math.abs(e.translationX) > SWIPE_THRESHOLD) {
              if (e.translationX < 0 && canGoNext) runOnJS(goForward)();
              else if (e.translationX > 0 && canGoPrev) runOnJS(goBack)();
            }
            return;
          }
          const vel = Math.abs(e.velocityX / 1000);
          const committed =
            Math.abs(e.translationX) > SWIPE_THRESHOLD || vel > 0.5;
          if (committed && e.translationX < 0 && canGoNext) {
            panX.value = withTiming(
              -SCREEN_W,
              {duration: animDuration},
              () => {
                panX.value = 0;
                runOnJS(goForward)();
              },
            );
          } else if (committed && e.translationX > 0 && canGoPrev) {
            panX.value = withTiming(
              SCREEN_W,
              {duration: animDuration},
              () => {
                panX.value = 0;
                runOnJS(goBack)();
              },
            );
          } else {
            panX.value = withSpring(0, {
              stiffness: 300,
              damping: 30,
              mass: 0.8,
            });
          }
        }),
    [pageMode, canGoPrev, canGoNext, goForward, goBack, animDuration, panX],
  );

  const tapGesture = useMemo(
    () =>
      Gesture.Tap().onEnd(e => {
        'worklet';
        const x = e.x;
        if (x < TAP_ZONE) {
          if (!canGoPrev) return;
          if (pageMode === 'none') {
            runOnJS(goBack)();
          } else {
            panX.value = withTiming(
              SCREEN_W,
              {duration: animDuration},
              () => {
                panX.value = 0;
                runOnJS(goBack)();
              },
            );
          }
        } else if (x > SCREEN_W - TAP_ZONE) {
          if (!canGoNext) return;
          if (pageMode === 'none') {
            runOnJS(goForward)();
          } else {
            panX.value = withTiming(
              -SCREEN_W,
              {duration: animDuration},
              () => {
                panX.value = 0;
                runOnJS(goForward)();
              },
            );
          }
        } else {
          runOnJS(onTapCenter)();
        }
      }),
    [pageMode, canGoPrev, canGoNext, goForward, goBack, onTapCenter, animDuration, panX],
  );

  const composed = Gesture.Exclusive(panGesture, tapGesture);

  const prevSlideStyle = useAnimatedStyle(() => ({
    transform: [{translateX: panX.value - SCREEN_W}],
  }));
  const curSlideStyle = useAnimatedStyle(() => ({
    transform: [{translateX: panX.value}],
  }));
  const nextSlideStyle = useAnimatedStyle(() => ({
    transform: [{translateX: panX.value + SCREEN_W}],
  }));

  // Cover: current page slides right (going back only)
  const coverCurStyle = useAnimatedStyle(() => ({
    transform: [{
      translateX: interpolate(panX.value, [0, SCREEN_W], [0, SCREEN_W], Extrapolation.CLAMP),
    }],
  }));
  // Cover: next page slides in from right (going forward only)
  const coverNextStyle = useAnimatedStyle(() => ({
    transform: [{
      translateX: interpolate(panX.value, [-SCREEN_W, 0], [0, SCREEN_W], Extrapolation.CLAMP),
    }],
  }));
  // Cover: prev page is static underneath, fades in slightly when revealed
  const coverPrevUnderStyle = useAnimatedStyle(() => ({
    opacity: interpolate(panX.value, [0, SCREEN_W * 0.3], [0.85, 1], Extrapolation.CLAMP),
  }));

  // Simulate: current page 3D flip
  const simCurStyle = useAnimatedStyle(() => {
    const rotY = interpolate(
      panX.value, [-SCREEN_W, 0, SCREEN_W], [-60, 0, 60], Extrapolation.CLAMP,
    );
    const sc = interpolate(
      panX.value, [-SCREEN_W, 0, SCREEN_W], [0.85, 1, 0.85], Extrapolation.CLAMP,
    );
    return {
      transform: [{perspective: 1200}, {rotateY: `${rotY}deg`}, {scale: sc}],
    };
  });
  // Simulate: next page (visible when swiping left)
  const simNextUnderStyle = useAnimatedStyle(() => ({
    opacity: interpolate(panX.value, [-SCREEN_W, -SCREEN_W * 0.1, 0], [1, 0.7, 0], Extrapolation.CLAMP),
  }));
  // Simulate: prev page (visible when swiping right)
  const simPrevUnderStyle = useAnimatedStyle(() => ({
    opacity: interpolate(panX.value, [0, SCREEN_W * 0.1, SCREEN_W], [0, 0.7, 1], Extrapolation.CLAMP),
  }));

  const renderPage = useCallback(
    (text: string, isFirst: boolean, pgIdx: number) => (
      <View
        style={[
          styles.pageContainer,
          {paddingTop: topInset + 12, paddingBottom: bottomInset + 12},
        ]}>
        <View style={styles.headerRow}>
          <Text style={[styles.headerIcon, {color: textColor, opacity: 0.4}]}>
            ‹
          </Text>
          <Text
            style={[styles.headerBookName, {color: textColor, opacity: 0.4}]}
            numberOfLines={1}>
            {bookName}
          </Text>
        </View>
        {isFirst && (
          <Text style={[styles.chapterTitle, {color: textColor}]}>
            {chapterTitle}
          </Text>
        )}
        <Text
          style={{
            fontSize,
            lineHeight: fontSize * lh,
            color: textColor,
            flex: 1,
          }}>
          {text}
        </Text>
        <View style={styles.footerRow}>
          <Text style={[styles.footerText, {color: textColor, opacity: 0.4}]}>
            {timeStr}
          </Text>
          <Text style={[styles.footerText, {color: textColor, opacity: 0.4}]}>
            {pgIdx + 1}/{pages.length}  {progress}%
          </Text>
        </View>
      </View>
    ),
    [topInset, bottomInset, textColor, bookName, chapterTitle, fontSize, lh, timeStr, pages.length, progress],
  );

  const currentPage = pages[pageIndex] || '';
  const prevPage = pageIndex > 0 ? pages[pageIndex - 1] : null;
  const nextPage = pageIndex < pages.length - 1 ? pages[pageIndex + 1] : null;

  if (pageMode === 'slide') {
    return (
      <GestureDetector gesture={composed}>
        <Animated.View
          style={[styles.flex, {backgroundColor: bgColor, overflow: 'hidden'}]}>
          {prevPage != null && (
            <Animated.View
              style={[styles.slidePage, {backgroundColor: bgColor}, prevSlideStyle]}
              pointerEvents="none">
              {renderPage(prevPage, pageIndex - 1 === 0, pageIndex - 1)}
            </Animated.View>
          )}
          <Animated.View
            style={[styles.slidePage, {backgroundColor: bgColor}, curSlideStyle]}>
            {renderPage(currentPage, pageIndex === 0, pageIndex)}
          </Animated.View>
          {nextPage != null && (
            <Animated.View
              style={[styles.slidePage, {backgroundColor: bgColor}, nextSlideStyle]}
              pointerEvents="none">
              {renderPage(nextPage, false, pageIndex + 1)}
            </Animated.View>
          )}
        </Animated.View>
      </GestureDetector>
    );
  }

  if (pageMode === 'cover') {
    return (
      <GestureDetector gesture={composed}>
        <Animated.View style={[styles.flex, {backgroundColor: bgColor}]}>
          {/* Layer 0: prev page underneath (visible when swiping right to go back) */}
          {prevPage != null && (
            <Animated.View
              style={[styles.coverUnder, {backgroundColor: bgColor}, coverPrevUnderStyle]}
              pointerEvents="none">
              {renderPage(prevPage, pageIndex - 1 === 0, pageIndex - 1)}
            </Animated.View>
          )}
          {/* Layer 1: current page (slides right when going back) */}
          <Animated.View
            style={[styles.coverOverlay, {backgroundColor: bgColor}, coverCurStyle]}>
            {renderPage(currentPage, pageIndex === 0, pageIndex)}
          </Animated.View>
          {/* Layer 2: next page (slides in from right when going forward) */}
          {nextPage != null && (
            <Animated.View
              style={[styles.coverOverlay, {backgroundColor: bgColor}, coverNextStyle]}
              pointerEvents="none">
              {renderPage(nextPage, false, pageIndex + 1)}
            </Animated.View>
          )}
        </Animated.View>
      </GestureDetector>
    );
  }

  if (pageMode === 'simulate') {
    return (
      <GestureDetector gesture={composed}>
        <Animated.View style={[styles.flex, {backgroundColor: bgColor}]}>
          {/* Next page underneath (visible when swiping left) */}
          {nextPage != null && (
            <Animated.View
              style={[styles.coverUnder, {backgroundColor: bgColor}, simNextUnderStyle]}
              pointerEvents="none">
              {renderPage(nextPage, false, pageIndex + 1)}
            </Animated.View>
          )}
          {/* Prev page underneath (visible when swiping right) */}
          {prevPage != null && (
            <Animated.View
              style={[styles.coverUnder, {backgroundColor: bgColor}, simPrevUnderStyle]}
              pointerEvents="none">
              {renderPage(prevPage, pageIndex - 1 === 0, pageIndex - 1)}
            </Animated.View>
          )}
          {/* Current page with 3D flip */}
          <Animated.View
            style={[styles.flex, {backgroundColor: bgColor}, simCurStyle]}>
            {renderPage(currentPage, pageIndex === 0, pageIndex)}
          </Animated.View>
        </Animated.View>
      </GestureDetector>
    );
  }

  return (
    <GestureDetector gesture={composed}>
      <Animated.View style={[styles.flex, {backgroundColor: bgColor}]}>
        {renderPage(currentPage, pageIndex === 0, pageIndex)}
      </Animated.View>
    </GestureDetector>
  );
}

// ─── 主组件 ───

export default function ReaderScreen() {
  const route = useRoute<ReaderRoute>();
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const {bookUrl, chapterIndex = 0, sourceUrl: paramSourceUrl, bookName: paramBookName, bookAuthor: paramBookAuthor} = route.params;

  const sources = useSourceStore(s => s.sources);
  const updateProgress = useBookshelfStore(s => s.updateProgress);
  const books = useBookshelfStore(s => s.books);
  const {settings, updateSettings} = useReaderStore();

  const [chapters, setChapters] = useState<Chapter[]>([]);
  const [currentIdx, setCurrentIdx] = useState(chapterIndex);
  const [content, setContent] = useState('');
  const [chapterTitle, setChapterTitle] = useState('');
  const [loading, setLoading] = useState(true);
  const [menuVisible, setMenuVisible] = useState(false);
  const [showToc, setShowToc] = useState(false);
  const [showStyle, setShowStyle] = useState(false);
  const [timeStr, setTimeStr] = useState(formatTime);
  const [pageIndex, setPageIndex] = useState(0);
  const [measuredLines, setMeasuredLines] = useState<TextLine[] | null>(null);
  const scrollRef = useRef<ScrollView>(null);
  const contentRevision = useRef(0);

  const book = books.find(b => b.bookUrl === bookUrl);
  const dynamicSourceRef = useRef<string | undefined>(undefined);
  const dynamicBookRef = useRef<string | undefined>(undefined);
  const bookName = book?.name || paramBookName || '';
  const initIdRef = useRef(0);

  useEffect(() => {
    const timer = setInterval(() => setTimeStr(formatTime()), 30000);
    return () => clearInterval(timer);
  }, []);

  // Reset measurement when content or style changes
  useEffect(() => {
    setMeasuredLines(null);
    contentRevision.current += 1;
  }, [content, settings.fontSize, settings.lineHeight]);

  const handleTextLayout = useCallback(
    (e: NativeSyntheticEvent<TextLayoutEventData>) => {
      const lines: TextLine[] = (e.nativeEvent as any).lines.map(
        (l: any) => ({
          text: l.text,
          width: l.width,
          height: l.height,
          y: l.y,
        }),
      );
      setMeasuredLines(lines);
    },
    [],
  );

  const pages = useMemo(() => {
    if (!content) return [''];
    if (measuredLines && measuredLines.length > 0) {
      return paginateByLines(measuredLines, insets.top, insets.bottom, true);
    }
    return estimatePages(
      content,
      settings.fontSize,
      settings.lineHeight,
      insets.top,
      insets.bottom,
    );
  }, [content, measuredLines, settings.fontSize, settings.lineHeight, insets.top, insets.bottom]);

  useEffect(() => {
    setPageIndex(0);
  }, [content]);

  const isLibraryUrl = bookUrl.startsWith('wanxiang://library/book/');

  async function loadLibraryContent(chapterUrl: string): Promise<string> {
    const parts = chapterUrl.split('/');
    const bookId = parseInt(parts[4] || '0', 10);
    const chIdx = parseInt(parts[6] || '0', 10);
    const resp = await fetchLibraryContent(bookId, chIdx);
    return resp.content;
  }

  const loadChapter = useCallback(
    async (idx: number) => {
      if (!chapters[idx]) return;
      const srcUrl = dynamicSourceRef.current || paramSourceUrl || book?.sourceUrl;
      const localSrc = srcUrl ? sources.find(s => s.bookSourceUrl === srcUrl) : undefined;
      if (!isLibraryUrl && !localSrc && !srcUrl) return;
      setLoading(true);
      try {
        let text = '';
        if (isLibraryUrl || chapters[idx].url.startsWith('wanxiang://library/')) {
          text = await loadLibraryContent(chapters[idx].url);
        } else if (localSrc) {
          try {
            text = await Promise.race([
              ruleEngine.getContent(localSrc, chapters[idx].url),
              new Promise<string>((_, rej) => setTimeout(() => rej(new Error('timeout')), 10000)),
            ]);
          } catch {}
        }
        if (!text && !isLibraryUrl && srcUrl) {
          try { text = await fetchProxyContent(srcUrl, chapters[idx].url); } catch {}
        }
        setContent(text || '内容为空');
        setChapterTitle(chapters[idx]?.title || '');
        setCurrentIdx(idx);
        setPageIndex(0);
        if (book) updateProgress(book.id, idx);
        scrollRef.current?.scrollTo({y: 0, animated: false});

        // Prefetch next 2 chapters
        if (srcUrl && !isLibraryUrl && !localSrc) {
          for (let n = 1; n <= 2; n++) {
            if (idx + n < chapters.length) {
              prefetchProxyContent(srcUrl, chapters[idx + n].url);
            }
          }
        }
      } catch (e: any) {
        setContent('加载失败: ' + e.message);
        setChapterTitle('错误');
      }
      setLoading(false);
    },
    [sources, chapters, book, paramSourceUrl, updateProgress, isLibraryUrl],
  );

  const [retryCount, setRetryCount] = useState(0);

  useEffect(() => {
    const runId = ++initIdRef.current;
    async function init() {
      const srcUrl = paramSourceUrl || book?.sourceUrl;
      const bUrl = bookUrl;
      const localSrc = srcUrl ? sources.find(s => s.bookSourceUrl === srcUrl) : undefined;
      if (!isLibraryUrl && !localSrc && !srcUrl) return;
      setLoading(true);
      const errors: string[] = [];
      try {
        let toc: Chapter[] = [];
        let usedOrigin = srcUrl;

        if (isLibraryUrl) {
          const bookId = parseInt(bUrl.split('/').pop() || '0', 10);
          const libChapters = await fetchLibraryChapters(bookId);
          toc = libChapters
            .filter(ch => ch.status === 'done')
            .map(ch => ({
              title: ch.title,
              url: `wanxiang://library/book/${bookId}/chapter/${ch.idx}`,
              index: ch.idx,
            }));
        } else if (localSrc) {
          try {
            toc = await Promise.race([
              ruleEngine.getToc(localSrc, bUrl),
              new Promise<Chapter[]>((_, rej) => setTimeout(() => rej(new Error('timeout')), 10000)),
            ]);
          } catch (e: any) {
            errors.push('本地源目录: ' + (e?.message || '失败'));
          }
        }
        if (!isLibraryUrl && !localSrc && srcUrl && toc.length === 0) {
          try {
            const proxyChapters = await fetchProxyToc(srcUrl, bUrl);
            toc = proxyChapters.map((ch, i) => ({title: ch.title, url: ch.url, index: i}));
          } catch (e: any) {
            errors.push('代理目录: ' + (e?.message || '失败'));
          }
        }

        if (runId !== initIdRef.current) return;

        if (toc.length === 0 && bookName) {
          try {
            const candidates = await changeSourceSearch(bookName, paramBookAuthor || book?.author || '', 3);
            for (const alt of candidates) {
              if (alt.origin === srcUrl) continue;
              try {
                const altToc = await fetchProxyToc(alt.origin, alt.bookUrl);
                if (altToc.length > 0) {
                  toc = altToc.map((ch, i) => ({title: ch.title, url: ch.url, index: i}));
                  usedOrigin = alt.origin;
                  dynamicSourceRef.current = alt.origin;
                  dynamicBookRef.current = alt.bookUrl;
                  break;
                }
              } catch {}
            }
            if (toc.length === 0) errors.push('换源(' + candidates.length + '个)均无目录');
          } catch (e: any) {
            errors.push('换源搜索: ' + (e?.message || '失败'));
          }
        }

        if (runId !== initIdRef.current) return;

        setChapters(toc);
        if (toc.length > 0) {
          const idx = Math.min(chapterIndex, toc.length - 1);
          let text = '';
          if (isLibraryUrl || toc[idx].url.startsWith('wanxiang://library/')) {
            text = await loadLibraryContent(toc[idx].url);
          } else if (localSrc) {
            try {
              text = await Promise.race([
                ruleEngine.getContent(localSrc, toc[idx].url),
                new Promise<string>((_, rej) => setTimeout(() => rej(new Error('timeout')), 10000)),
              ]);
            } catch {}
          }
          if (!text && !isLibraryUrl) {
            const contentOrigin = usedOrigin || srcUrl || paramSourceUrl;
            const contentChUrl = toc[idx].url;
            if (contentOrigin && contentChUrl) {
              try { text = await fetchProxyContent(contentOrigin, contentChUrl); } catch {}
            }
          }
          if (runId !== initIdRef.current) return;
          if (!text && bookName) {
            try {
              const altSources = await changeSourceSearch(bookName, paramBookAuthor || book?.author || '', 5);
              for (const alt of altSources) {
                if (alt.origin === usedOrigin) continue;
                try {
                  const altToc = await fetchProxyToc(alt.origin, alt.bookUrl);
                  if (altToc.length > 0) {
                    const altIdx = Math.min(idx, altToc.length - 1);
                    const altText = await fetchProxyContent(alt.origin, altToc[altIdx].url);
                    if (altText) {
                      text = altText;
                      toc = altToc.map((ch, i) => ({title: ch.title, url: ch.url, index: i}));
                      dynamicSourceRef.current = alt.origin;
                      dynamicBookRef.current = alt.bookUrl;
                      setChapters(toc);
                      break;
                    }
                  }
                } catch {}
              }
            } catch {}
          }
          if (runId !== initIdRef.current) return;
          setContent(text || '内容为空');
          setChapterTitle(toc[idx].title);
          setCurrentIdx(idx);

          if (usedOrigin && !isLibraryUrl && !localSrc) {
            for (let n = 1; n <= 2; n++) {
              if (idx + n < toc.length) prefetchProxyContent(usedOrigin, toc[idx + n].url);
            }
          }
        } else {
          const detail = errors.length > 0 ? '\n' + errors.join('\n') : '';
          setContent('目录加载失败，点击底部重试' + detail);
          setChapterTitle('提示');
        }
      } catch (e: any) {
        if (runId !== initIdRef.current) return;
        setContent('加载失败: ' + (e?.message || '未知错误'));
        setChapterTitle('错误');
      }
      setLoading(false);
    }
    init();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookUrl, chapterIndex, isLibraryUrl, paramSourceUrl, retryCount]);

  const goPrev = () => {
    if (currentIdx > 0) loadChapter(currentIdx - 1);
  };
  const goNext = () => {
    if (currentIdx < chapters.length - 1) loadChapter(currentIdx + 1);
  };

  const handleTap = (x: number) => {
    if (x < TAP_ZONE) {
      goPrev();
    } else if (x > SCREEN_W - TAP_ZONE) {
      goNext();
    } else {
      setMenuVisible(v => !v);
    }
  };

  const bgColor = settings.backgroundColor;
  const textColor = settings.textColor;
  const chapterProgress =
    chapters.length > 0
      ? ((currentIdx / chapters.length) * 100).toFixed(1)
      : '0.0';

  const isScrollMode = settings.pageMode === 'scroll';

  return (
    <View style={[styles.container, {backgroundColor: bgColor}]}>
      <StatusBar hidden={!menuVisible} />

      {/* Hidden text for measurement — triggers onTextLayout for precise pagination */}
      {!isScrollMode && content && !measuredLines && (
        <View style={styles.measureContainer} pointerEvents="none">
          <Text
            style={{
              fontSize: settings.fontSize,
              lineHeight: settings.fontSize * settings.lineHeight,
              color: 'transparent',
              width: SCREEN_W - 2 * H_PADDING,
            }}
            onTextLayout={handleTextLayout}>
            {content}
          </Text>
        </View>
      )}

      {loading ? (
        <View style={styles.center}>
          {chapterTitle ? (
            <Text
              style={[styles.loadingTitle, {color: textColor}]}
              numberOfLines={2}>
              {chapterTitle}
            </Text>
          ) : null}
          <ActivityIndicator size="large" color={textColor} />
          <Text style={[styles.loadingHint, {color: textColor, opacity: 0.6}]}>
            {chapters.length === 0 ? '加载目录…' : '加载正文…'}
          </Text>
        </View>
      ) : chapters.length === 0 && !isLibraryUrl ? (
        <View style={styles.center}>
          <Text style={[styles.loadingHint, {color: textColor, marginBottom: 16, textAlign: 'center', paddingHorizontal: 30}]}>
            {content || '目录加载失败'}
          </Text>
          <TouchableOpacity
            style={[styles.navBtn, {paddingHorizontal: 28, paddingVertical: 10}]}
            onPress={() => setRetryCount(c => c + 1)}>
            <Text style={styles.navBtnText}>重新加载</Text>
          </TouchableOpacity>
        </View>
      ) : isScrollMode ? (
        /* ── 滚动模式 ── */
        <TouchableOpacity
          activeOpacity={1}
          onPress={e => handleTap(e.nativeEvent.locationX)}
          style={styles.flex}>
          <ScrollView
            ref={scrollRef}
            style={styles.flex}
            contentContainerStyle={[
              styles.scrollContent,
              {paddingTop: insets.top + 12, paddingBottom: insets.bottom + 30},
            ]}
            showsVerticalScrollIndicator={false}>
            <View style={styles.headerRow}>
              <Text
                style={[
                  styles.headerIcon,
                  {color: textColor, opacity: 0.4},
                ]}>
                ‹
              </Text>
              <Text
                style={[
                  styles.headerBookName,
                  {color: textColor, opacity: 0.4},
                ]}
                numberOfLines={1}>
                {bookName}
              </Text>
            </View>

            <Text style={[styles.chapterTitle, {color: textColor}]}>
              {chapterTitle}
            </Text>

            <Text
              style={{
                fontSize: settings.fontSize,
                lineHeight: settings.fontSize * settings.lineHeight,
                color: textColor,
              }}>
              {content}
            </Text>

            <View style={styles.bottomNav}>
              <TouchableOpacity
                onPress={goPrev}
                disabled={currentIdx === 0}
                style={[styles.navBtn, currentIdx === 0 && styles.disabled]}>
                <Text style={styles.navBtnText}>上一章</Text>
              </TouchableOpacity>
              <Text style={[styles.navProgress, {color: textColor}]}>
                {currentIdx + 1} / {chapters.length}
              </Text>
              <TouchableOpacity
                onPress={goNext}
                disabled={currentIdx >= chapters.length - 1}
                style={[
                  styles.navBtn,
                  currentIdx >= chapters.length - 1 && styles.disabled,
                ]}>
                <Text style={styles.navBtnText}>下一章</Text>
              </TouchableOpacity>
            </View>

            <View style={styles.footerRow}>
              <Text
                style={[
                  styles.footerText,
                  {color: textColor, opacity: 0.4},
                ]}>
                {timeStr}
              </Text>
              <Text
                style={[
                  styles.footerText,
                  {color: textColor, opacity: 0.4},
                ]}>
                {chapterProgress}%
              </Text>
            </View>
          </ScrollView>
        </TouchableOpacity>
      ) : (
        /* ── 翻页模式 (cover / slide / simulate / none) ── */
        <PagedReader
          pages={pages}
          pageIndex={pageIndex}
          onPageChange={setPageIndex}
          onTapCenter={() => setMenuVisible(v => !v)}
          fontSize={settings.fontSize}
          lineHeight={settings.lineHeight}
          textColor={textColor}
          bgColor={bgColor}
          chapterTitle={chapterTitle}
          bookName={bookName}
          timeStr={timeStr}
          progress={chapterProgress}
          pageMode={settings.pageMode}
          topInset={insets.top}
          bottomInset={insets.bottom}
          onPrevChapter={goPrev}
          onNextChapter={goNext}
          hasPrevChapter={currentIdx > 0}
          hasNextChapter={currentIdx < chapters.length - 1}
          totalChapters={chapters.length}
          currentChapterIdx={currentIdx}
        />
      )}

      {/* ── 菜单 overlay ── */}
      {menuVisible && (
        <View style={styles.menuOverlay}>
          <View style={[styles.topBar, {paddingTop: insets.top + 8}]}>
            <TouchableOpacity
              onPress={() => navigation.goBack()}
              style={styles.backBtn}>
              <Ionicons name="chevron-back" size={20} color="#fff" />
            </TouchableOpacity>
            <Text style={styles.topTitle} numberOfLines={1}>
              {chapterTitle}
            </Text>
            <View style={{width: 40}} />
          </View>

          <TouchableOpacity
            style={styles.menuMiddle}
            activeOpacity={1}
            onPress={() => setMenuVisible(false)}
          />

          <View style={[styles.controlBar, {paddingBottom: insets.bottom + 14}]}>
            {chapters.length > 1 && (
              <View style={styles.sliderRow}>
                <Text style={styles.sliderText}>{currentIdx + 1}</Text>
                <View style={styles.sliderTrack}>
                  <View
                    style={[
                      styles.sliderFill,
                      {
                        width: `${
                          (currentIdx / (chapters.length - 1)) * 100
                        }%`,
                      },
                    ]}
                  />
                </View>
                <Text style={styles.sliderText}>{chapters.length}</Text>
              </View>
            )}

            <View style={styles.ctrlRow}>
              <TouchableOpacity
                style={styles.ctrlIconBtn}
                onPress={goPrev}
                disabled={currentIdx === 0}>
                <Ionicons
                  name="chevron-back"
                  size={20}
                  color={currentIdx === 0 ? '#666' : '#fff'}
                />
                <Text
                  style={[
                    styles.ctrlLabel,
                    currentIdx === 0 && {color: '#666'},
                  ]}>
                  上一章
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.ctrlIconBtn}
                onPress={() => {
                  setMenuVisible(false);
                  setShowToc(true);
                }}>
                <Ionicons name="list" size={20} color="#fff" />
                <Text style={styles.ctrlLabel}>目录</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.ctrlIconBtn}
                onPress={() => {
                  setMenuVisible(false);
                  setShowStyle(true);
                }}>
                <Ionicons name="text" size={20} color="#fff" />
                <Text style={styles.ctrlLabel}>设置</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.ctrlIconBtn}
                onPress={goNext}
                disabled={currentIdx >= chapters.length - 1}>
                <Ionicons
                  name="chevron-forward"
                  size={20}
                  color={currentIdx >= chapters.length - 1 ? '#666' : '#fff'}
                />
                <Text
                  style={[
                    styles.ctrlLabel,
                    currentIdx >= chapters.length - 1 && {color: '#666'},
                  ]}>
                  下一章
                </Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      )}

      {/* ── 目录 Modal ── */}
      <Modal
        visible={showToc}
        transparent
        animationType="slide"
        onRequestClose={() => setShowToc(false)}>
        <View style={styles.tocOverlay}>
          <TouchableOpacity
            style={styles.tocBackdrop}
            activeOpacity={1}
            onPress={() => setShowToc(false)}
          />
          <View style={[styles.tocPanel, {paddingTop: insets.top + 10}]}>
            <View style={styles.tocHeader}>
              <Text style={styles.tocTitle}>
                目录 ({chapters.length}章)
              </Text>
              <TouchableOpacity onPress={() => setShowToc(false)}>
                <Text style={styles.tocClose}>✕</Text>
              </TouchableOpacity>
            </View>
            <FlatList
              data={chapters}
              keyExtractor={item => String(item.index)}
              initialScrollIndex={Math.max(
                0,
                Math.min(currentIdx, chapters.length - 1),
              )}
              getItemLayout={(_d, i) => ({
                length: 44,
                offset: 44 * i,
                index: i,
              })}
              renderItem={({item}) => (
                <TouchableOpacity
                  style={[
                    styles.tocItem,
                    item.index === currentIdx && styles.tocItemActive,
                  ]}
                  onPress={() => {
                    setShowToc(false);
                    loadChapter(item.index);
                  }}>
                  <Text
                    style={[
                      styles.tocItemText,
                      item.index === currentIdx && styles.tocItemTextActive,
                    ]}
                    numberOfLines={1}>
                    {item.title}
                  </Text>
                </TouchableOpacity>
              )}
            />
          </View>
        </View>
      </Modal>

      {/* ── 设置 Modal (对齐 iOS ReadStyleSheet) ── */}
      <Modal
        visible={showStyle}
        transparent
        animationType="slide"
        onRequestClose={() => setShowStyle(false)}>
        <View style={styles.styleOverlay}>
          <TouchableOpacity
            style={styles.tocBackdrop}
            activeOpacity={1}
            onPress={() => setShowStyle(false)}
          />
          <View
            style={[styles.stylePanel, {paddingBottom: insets.bottom + 20}]}>
            <View style={styles.styleTitleRow}>
              <Text style={styles.styleTitleText}>阅读样式</Text>
              <TouchableOpacity onPress={() => setShowStyle(false)}>
                <Text style={styles.styleDoneBtn}>完成</Text>
              </TouchableOpacity>
            </View>

            {/* Section 1: 主题 */}
            <Text style={styles.styleSectionTitle}>主题</Text>
            <View style={styles.themeRow}>
              {THEMES.map(opt => (
                <TouchableOpacity
                  key={opt.key}
                  style={styles.themeItem}
                  onPress={() =>
                    updateSettings({
                      backgroundColor: opt.bg,
                      textColor: opt.text,
                    })
                  }>
                  <View
                    style={[
                      styles.themeCircle,
                      {backgroundColor: opt.bg},
                      settings.backgroundColor === opt.bg &&
                        styles.themeCircleActive,
                    ]}>
                    <Text style={{color: opt.text, fontSize: 11}}>阅</Text>
                  </View>
                  <Text style={styles.themeLabel}>{opt.label}</Text>
                </TouchableOpacity>
              ))}
            </View>

            {/* Section 2: 排版 — 字号 */}
            <Text style={styles.styleSectionTitle}>排版</Text>
            <View style={styles.fontSizeRow}>
              <Text style={styles.fontSizeLabel}>字号</Text>
              <TouchableOpacity
                style={styles.fontSizeBtn}
                onPress={() =>
                  updateSettings({
                    fontSize: Math.max(12, settings.fontSize - 1),
                  })
                }>
                <Text style={styles.fontSizeBtnText}>A-</Text>
              </TouchableOpacity>
              <Text style={styles.fontSizeValue}>{settings.fontSize}</Text>
              <TouchableOpacity
                style={styles.fontSizeBtn}
                onPress={() =>
                  updateSettings({
                    fontSize: Math.min(32, settings.fontSize + 1),
                  })
                }>
                <Text style={styles.fontSizeBtnText}>A+</Text>
              </TouchableOpacity>
            </View>

            {/* 行距 */}
            <View style={styles.fontSizeRow}>
              <Text style={styles.fontSizeLabel}>行距</Text>
              {[1.2, 1.5, 1.8, 2.0, 2.5].map(lhVal => (
                <TouchableOpacity
                  key={lhVal}
                  style={[
                    styles.lineHeightBtn,
                    settings.lineHeight === lhVal && styles.lineHeightBtnActive,
                  ]}
                  onPress={() => updateSettings({lineHeight: lhVal})}>
                  <Text
                    style={[
                      styles.lineHeightText,
                      settings.lineHeight === lhVal &&
                        styles.lineHeightTextActive,
                    ]}>
                    {lhVal.toFixed(1)}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            {/* Section 3: 翻页方式 (5 选 1, 同 iOS) */}
            <Text style={styles.styleSectionTitle}>翻页方式</Text>
            <View style={styles.pageAnimRow}>
              {PAGE_MODES.map((pm, i) => {
                const active = settings.pageMode === pm.key;
                return (
                  <TouchableOpacity
                    key={pm.key}
                    style={[
                      styles.pageAnimBtn,
                      active && styles.pageAnimBtnActive,
                      i === 0 && styles.pageAnimBtnLeft,
                      i === PAGE_MODES.length - 1 && styles.pageAnimBtnRight,
                    ]}
                    onPress={() => updateSettings({pageMode: pm.key})}>
                    <Text
                      style={[
                        styles.pageAnimText,
                        active && styles.pageAnimTextActive,
                      ]}>
                      {pm.label}
                    </Text>
                  </TouchableOpacity>
                );
              })}
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1},
  flex: {flex: 1},
  measureContainer: {
    position: 'absolute',
    top: -9999,
    left: 0,
    right: 0,
    opacity: 0,
  },
  center: {flex: 1, justifyContent: 'center', alignItems: 'center', gap: 14},
  loadingTitle: {
    fontSize: 17,
    fontWeight: '500',
    textAlign: 'center',
    paddingHorizontal: 32,
  },
  loadingHint: {fontSize: 12},
  scrollContent: {paddingHorizontal: H_PADDING},

  // Page container (paged mode)
  pageContainer: {
    flex: 1,
    paddingHorizontal: H_PADDING,
    justifyContent: 'space-between',
  },

  // Page header
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    marginBottom: 8,
    height: HEADER_H,
  },
  headerIcon: {fontSize: 9, fontWeight: '500'},
  headerBookName: {fontSize: 11},

  // Chapter title
  chapterTitle: {
    fontSize: FontSize.lg,
    fontWeight: '600',
    marginBottom: Spacing.lg,
    textAlign: 'center',
  },

  // Bottom nav (scroll mode)
  bottomNav: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: Spacing.xl,
    paddingVertical: Spacing.md,
  },
  navBtn: {
    paddingHorizontal: Spacing.md,
    paddingVertical: 8,
    borderRadius: Radius.sm,
    backgroundColor: Colors.primary,
  },
  navBtnText: {color: Colors.white, fontSize: 13},
  navProgress: {fontSize: 13},
  disabled: {opacity: 0.3},

  // Page footer
  footerRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 8,
    height: FOOTER_H,
    alignItems: 'flex-end',
  },
  footerText: {fontSize: 11, fontVariant: ['tabular-nums']},

  // Slide pages
  slidePage: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: SCREEN_W,
    bottom: 0,
  },

  // Cover under page
  coverUnder: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  },

  // Cover overlay (current page that slides)
  coverOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    elevation: 8,
    shadowColor: '#000',
    shadowOffset: {width: -4, height: 0},
    shadowOpacity: 0.25,
    shadowRadius: 12,
  },

  // Cover edge shadow (thin dark strip at the sliding edge)
  coverEdgeShadow: {
    position: 'absolute',
    top: 0,
    width: 20,
    bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.6)',
  },

  // Menu overlay
  menuOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 100,
  },
  menuMiddle: {flex: 1},

  // Top bar
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.7)',
    paddingBottom: 12,
    paddingHorizontal: 16,
  },
  backBtn: {width: 40},
  topTitle: {
    flex: 1,
    color: '#fff',
    fontSize: 15,
    fontWeight: '500',
    textAlign: 'center',
  },

  // Bottom control bar
  controlBar: {
    backgroundColor: 'rgba(0,0,0,0.7)',
    paddingTop: 14,
  },
  sliderRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    marginBottom: 14,
    gap: 8,
  },
  sliderText: {
    color: '#fff',
    fontSize: 12,
    fontVariant: ['tabular-nums'],
    minWidth: 30,
    textAlign: 'center',
  },
  sliderTrack: {
    flex: 1,
    height: 4,
    backgroundColor: 'rgba(255,255,255,0.3)',
    borderRadius: 2,
    overflow: 'hidden',
  },
  sliderFill: {
    height: '100%',
    backgroundColor: Colors.primary,
    borderRadius: 2,
  },
  ctrlRow: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    paddingHorizontal: 16,
  },
  ctrlIconBtn: {
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  ctrlLabel: {color: '#fff', fontSize: 10, marginTop: 4},

  // TOC
  tocOverlay: {
    flex: 1,
    flexDirection: 'row',
  },
  tocBackdrop: {flex: 1, backgroundColor: 'rgba(0,0,0,0.4)'},
  tocPanel: {
    width: 280,
    backgroundColor: Colors.card,
  },
  tocHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingBottom: Spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.divider,
  },
  tocTitle: {
    fontSize: FontSize.md,
    fontWeight: '600',
    color: Colors.textPrimary,
  },
  tocClose: {fontSize: 18, color: Colors.textSecondary, padding: 4},
  tocItem: {
    height: 44,
    justifyContent: 'center',
    paddingHorizontal: Spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.divider,
  },
  tocItemActive: {backgroundColor: `${Colors.primary}1F`},
  tocItemText: {fontSize: 13, color: Colors.textPrimary},
  tocItemTextActive: {color: Colors.primary, fontWeight: '600'},

  // Style panel (对齐 iOS ReadStyleSheet)
  styleOverlay: {
    flex: 1,
    justifyContent: 'flex-end',
  },
  stylePanel: {
    backgroundColor: Colors.card,
    paddingHorizontal: Spacing.md,
    paddingTop: 12,
    borderTopLeftRadius: Radius.lg,
    borderTopRightRadius: Radius.lg,
  },
  styleTitleRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 4,
  },
  styleTitleText: {
    fontSize: 16,
    fontWeight: '600',
    color: Colors.textPrimary,
  },
  styleDoneBtn: {
    fontSize: 15,
    fontWeight: '600',
    color: Colors.primary,
    paddingVertical: 4,
    paddingHorizontal: 8,
  },
  styleSectionTitle: {
    fontSize: 12,
    color: Colors.textSecondary,
    marginBottom: 8,
    marginTop: 14,
  },

  // Theme circles
  themeRow: {flexDirection: 'row', gap: 16},
  themeItem: {alignItems: 'center', gap: 4},
  themeCircle: {
    width: 36,
    height: 36,
    borderRadius: 18,
    justifyContent: 'center',
    alignItems: 'center',
    borderWidth: 2.5,
    borderColor: 'transparent',
  },
  themeCircleActive: {borderColor: Colors.primary},
  themeLabel: {fontSize: 10, color: Colors.textSecondary},

  // Font size row
  fontSizeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginBottom: 8,
  },
  fontSizeLabel: {
    width: 36,
    fontSize: 14,
    color: Colors.textPrimary,
  },
  fontSizeBtn: {
    width: 48,
    height: 34,
    borderRadius: 8,
    backgroundColor: Colors.background,
    justifyContent: 'center',
    alignItems: 'center',
  },
  fontSizeBtnText: {
    fontSize: 15,
    fontWeight: '500',
    color: Colors.textPrimary,
  },
  fontSizeValue: {
    fontSize: 18,
    fontWeight: '600',
    color: Colors.textPrimary,
    minWidth: 36,
    textAlign: 'center',
    fontVariant: ['tabular-nums'] as any,
  },

  // Line height
  lineHeightBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: Radius.sm,
    backgroundColor: Colors.background,
  },
  lineHeightBtnActive: {backgroundColor: Colors.primary},
  lineHeightText: {fontSize: 13, color: Colors.textPrimary},
  lineHeightTextActive: {color: '#fff'},

  // Page animation (5-segment picker, like iOS segmented control)
  pageAnimRow: {
    flexDirection: 'row',
    backgroundColor: Colors.background,
    borderRadius: 8,
    overflow: 'hidden',
  },
  pageAnimBtn: {
    flex: 1,
    paddingVertical: 8,
    alignItems: 'center',
  },
  pageAnimBtnActive: {
    backgroundColor: Colors.primary,
  },
  pageAnimBtnLeft: {
    borderTopLeftRadius: 8,
    borderBottomLeftRadius: 8,
  },
  pageAnimBtnRight: {
    borderTopRightRadius: 8,
    borderBottomRightRadius: 8,
  },
  pageAnimText: {fontSize: 13, color: Colors.textPrimary},
  pageAnimTextActive: {fontSize: 13, color: '#fff', fontWeight: '500'},
});
