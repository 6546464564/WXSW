/**
 * 万象书屋 RN · 导航
 * 1:1 对齐 iOS: RootView.swift + CustomTabBar
 * 3 Tab: 书架 / 书城 / 我的
 * CustomTabBar: 白色卡片 + 顶部细线 + 选中棕金 pill
 */

import React, {useRef, useEffect} from 'react';
import {View, Text, TouchableOpacity, StyleSheet, Platform} from 'react-native';
import {NavigationContainer, DefaultTheme, DarkTheme, createNavigationContainerRef} from '@react-navigation/native';
import {createBottomTabNavigator} from '@react-navigation/bottom-tabs';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {useThemeColors, FontSize, Radius} from './theme';

import BookshelfScreen from '../features/bookshelf/BookshelfScreen';
import BookStoreScreen from '../features/bookstore/BookStoreScreen';
import MyScreen from '../features/settings/SettingsScreen';
import SearchScreen from '../features/search/SearchScreen';
import ReaderScreen from '../features/reader/ReaderScreen';
import BookDetailScreen from '../features/detail/BookDetailScreen';
import RankDetailScreen from '../features/bookstore/RankDetailScreen';
import DownloadCenterScreen from '../features/download/DownloadCenterScreen';
import type {Channel} from '../api/bookstore';

export type RootStackParamList = {
  Main: undefined;
  Reader: {bookUrl: string; chapterIndex?: number; sourceUrl?: string; bookName?: string; bookAuthor?: string};
  BookDetail: {
    bookUrl?: string;
    sourceUrl?: string;
    bookName?: string;
    bookAuthor?: string;
    bookCover?: string;
    bookIntro?: string;
  };
  Search: {keyword?: string};
  RankDetail: {mode: 'rank' | 'finish'; channel: Channel; title: string; rankType?: string};
  DownloadCenter: undefined;
};

export type TabParamList = {
  Bookshelf: undefined;
  BookStore: undefined;
  My: undefined;
};

const Stack = createNativeStackNavigator<RootStackParamList>();
const Tab = createBottomTabNavigator<TabParamList>();

const TAB_ITEMS: {
  name: keyof TabParamList;
  label: string;
  iconOff: string;
  iconOn: string;
}[] = [
  {name: 'Bookshelf', label: '书架', iconOff: 'library-outline', iconOn: 'library'},
  {name: 'BookStore', label: '书城', iconOff: 'business-outline', iconOn: 'business'},
  {name: 'My', label: '我的', iconOff: 'person-circle-outline', iconOn: 'person-circle'},
];

function CustomTabBar({state, navigation}: any) {
  const insets = useSafeAreaInsets();
  const colors = useThemeColors();

  return (
    <View
      style={[
        styles.tabBarOuter,
        {paddingBottom: Math.max(8, insets.bottom - 18), backgroundColor: colors.card},
      ]}>
      <View style={[styles.tabBarTopLine, {backgroundColor: `${colors.divider}D9`}]} />
      <View style={styles.tabBarInner}>
        {TAB_ITEMS.map((item, index) => {
          const focused = state.index === index;
          const color = focused
            ? colors.primary
            : `${colors.textSecondary}B8`;

          return (
            <TouchableOpacity
              key={item.name}
              style={styles.tabBtn}
              activeOpacity={0.7}
              onPress={() => {
                const route = state.routes[index];
                const event = navigation.emit({
                  type: 'tabPress',
                  target: route.key,
                  canPreventDefault: true,
                });
                if (!event.defaultPrevented) {
                  navigation.navigate(route.name);
                }
              }}>
              <View
                style={[
                  styles.tabPill,
                  focused && styles.tabPillActive,
                ]}>
                <Ionicons
                  name={focused ? item.iconOn : item.iconOff}
                  size={21}
                  color={color}
                  style={{marginBottom: 2}}
                />
                <Text
                  style={[
                    styles.tabLabel,
                    {
                      color,
                      fontWeight: focused ? '600' : '400',
                    },
                  ]}>
                  {item.label}
                </Text>
              </View>
            </TouchableOpacity>
          );
        })}
      </View>
    </View>
  );
}

function MainTabs() {
  return (
    <Tab.Navigator
      tabBar={props => <CustomTabBar {...props} />}
      screenOptions={{headerShown: false}}>
      <Tab.Screen name="Bookshelf" component={BookshelfScreen} />
      <Tab.Screen name="BookStore" component={BookStoreScreen} />
      <Tab.Screen name="My" component={MyScreen} />
    </Tab.Navigator>
  );
}

const navRef = createNavigationContainerRef<RootStackParamList>();

const __DEBUG_AUTO_NAV__ = false;

export default function Navigation() {
  const colors = useThemeColors();
  const didAutoNav = useRef(false);

  useEffect(() => {
    if (!__DEBUG_AUTO_NAV__ || didAutoNav.current) return;
    const timer = setTimeout(() => {
      if (navRef.isReady() && !didAutoNav.current) {
        didAutoNav.current = true;
        navRef.navigate('Reader', {
          bookUrl: 'https://h5.h5bookyyds.com/d-aDUuaDVib29reXlkcy5jb20=/book/1095806',
          chapterIndex: 0,
          sourceUrl: 'https://h5.h5bookyyds.com',
          bookName: '以一龙之力打倒整个世界！',
          bookAuthor: '',
        });
      }
    }, 2000);
    return () => clearTimeout(timer);
  }, []);

  const navTheme = colors.isDark
    ? {
        ...DarkTheme,
        colors: {...DarkTheme.colors, primary: colors.primary, background: colors.background, card: colors.card},
      }
    : {
        ...DefaultTheme,
        colors: {...DefaultTheme.colors, primary: colors.primary, background: colors.background, card: colors.card},
      };

  return (
    <NavigationContainer ref={navRef} theme={navTheme}>
      <Stack.Navigator screenOptions={{headerShown: false}}>
        <Stack.Screen name="Main" component={MainTabs} />
        <Stack.Screen
          name="Reader"
          component={ReaderScreen}
          options={{animation: 'fade'}}
        />
        <Stack.Screen
          name="BookDetail"
          component={BookDetailScreen}
          options={{
            headerShown: true,
            title: '书籍详情',
            headerTintColor: colors.primary,
            headerStyle: {backgroundColor: colors.background},
          }}
        />
        <Stack.Screen
          name="Search"
          component={SearchScreen}
          options={{
            headerShown: true,
            title: '搜索',
            headerTintColor: colors.primary,
            headerStyle: {backgroundColor: colors.background},
          }}
        />
        <Stack.Screen
          name="RankDetail"
          component={RankDetailScreen}
          options={({route}) => ({
            headerShown: true,
            title: (route.params as RootStackParamList['RankDetail']).title,
            headerTintColor: colors.primary,
            headerStyle: {backgroundColor: colors.background},
          })}
        />
        <Stack.Screen
          name="DownloadCenter"
          component={DownloadCenterScreen}
          options={{
            headerShown: true,
            title: '下载中心',
            headerTintColor: colors.primary,
            headerStyle: {backgroundColor: colors.background},
          }}
        />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  tabBarOuter: {
    ...Platform.select({
      ios: {
        shadowColor: '#000',
        shadowOffset: {width: 0, height: -1},
        shadowOpacity: 0.05,
        shadowRadius: 4,
      },
      android: {elevation: 8},
    }),
  },
  tabBarTopLine: {
    height: 0.5,
  },
  tabBarInner: {
    flexDirection: 'row',
    height: 54,
    paddingHorizontal: 14,
    paddingTop: 6,
    alignItems: 'center',
    justifyContent: 'space-around',
  },
  tabBtn: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    height: 46,
  },
  tabPill: {
    width: 76,
    height: 46,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: Radius.lg,
  },
  tabPillActive: {
    backgroundColor: 'rgba(184, 149, 107, 0.16)',
    borderWidth: 0.5,
    borderColor: 'rgba(184, 149, 107, 0.10)',
  },
  tabLabel: {
    fontSize: FontSize.xs,
  },
});
