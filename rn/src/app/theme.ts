/**
 * 万象书屋 RN · 设计系统
 * 对齐 iOS: WanxiangColors.swift
 * 品牌色: 棕金 #B8956B
 */

import {useColorScheme} from 'react-native';

export interface ThemeColors {
  primary: string;
  accent: string;
  background: string;
  card: string;
  textPrimary: string;
  textSecondary: string;
  divider: string;
  error: string;
  success: string;
  white: string;
  isDark: boolean;
  reader: {
    default: {bg: string; text: string};
    eye: {bg: string; text: string};
    night: {bg: string; text: string};
    parchment: {bg: string; text: string};
  };
}

const LightColors: ThemeColors = {
  primary: '#B8956B',
  accent: '#A69374',
  background: '#F5EFE6',
  card: '#FFFAF3',
  textPrimary: '#3E2D1B',
  textSecondary: '#7B6A55',
  divider: '#E0D3BC',
  error: '#E53935',
  success: '#43A047',
  white: '#FFFFFF',
  isDark: false,
  reader: {
    default: {bg: '#FFFFF2', text: '#3E2D1B'},
    eye: {bg: '#C7EDCC', text: '#333333'},
    night: {bg: '#161616', text: '#9B968C'},
    parchment: {bg: '#F5E6D0', text: '#4A3728'},
  },
};

const DarkColors: ThemeColors = {
  primary: '#C9A67A',
  accent: '#B8A588',
  background: '#161616',
  card: '#22201D',
  textPrimary: '#E8E0D4',
  textSecondary: '#9B968C',
  divider: '#3A3530',
  error: '#EF5350',
  success: '#66BB6A',
  white: '#FFFFFF',
  isDark: true,
  reader: {
    default: {bg: '#1A1A1A', text: '#D4CBB8'},
    eye: {bg: '#1A2E1C', text: '#A8D5AA'},
    night: {bg: '#0D0D0D', text: '#7A756C'},
    parchment: {bg: '#2A2218', text: '#D4C4A8'},
  },
};

/**
 * 响应系统暗黑模式的 hook。
 * 各页面逐步从静态 Colors 迁移到 useThemeColors()。
 */
export function useThemeColors(): ThemeColors {
  const scheme = useColorScheme();
  return scheme === 'dark' ? DarkColors : LightColors;
}

/** 静态引用 (浅色), 供不在 React 组件中的代码使用 */
export const Colors = LightColors;

export const Spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
};

export const FontSize = {
  xs: 10.5,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 20,
  xxl: 28,
};

export const Radius = {
  sm: 6,
  md: 10,
  lg: 16,
  xl: 24,
};

/** 对齐 iOS BookCover.colorPair: 8 组渐变色, 按书名哈希挑选 */
export const CoverPalettes: [string, string][] = [
  ['rgba(194,107,87,1)', 'rgba(133,51,41,1)'],
  ['rgba(102,133,184,1)', 'rgba(46,71,122,1)'],
  ['rgba(143,107,173,1)', 'rgba(82,46,122,1)'],
  ['rgba(92,153,128,1)', 'rgba(41,92,77,1)'],
  ['rgba(199,148,87,1)', 'rgba(133,92,41,1)'],
  ['rgba(117,117,140,1)', 'rgba(61,61,82,1)'],
  ['rgba(173,92,128,1)', 'rgba(112,46,82,1)'],
  ['rgba(107,158,173,1)', 'rgba(51,102,122,1)'],
];
