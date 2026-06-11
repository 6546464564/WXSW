import React, {useEffect, useState} from 'react';
import {StatusBar, StyleSheet} from 'react-native';
import {NavigationContainer, DefaultTheme} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {createBottomTabNavigator} from '@react-navigation/bottom-tabs';
import {SafeAreaProvider, useSafeAreaInsets} from 'react-native-safe-area-context';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import HomeScreen from './screens/HomeScreen';
import AtlasScreen from './screens/AtlasScreen';
import GuideScreen from './screens/GuideScreen';
import GuideDetailScreen from './screens/GuideDetailScreen';
import LogScreen from './screens/LogScreen';
import ObservationDetailScreen from './screens/ObservationDetailScreen';
import SpeciesScreen from './screens/SpeciesScreen';
import CalendarScreen from './screens/CalendarScreen';
import ProfileScreen from './screens/ProfileScreen';
import SettingsScreen from './screens/SettingsScreen';
import PrivacyScreen from './screens/PrivacyScreen';
import TermsScreen from './screens/TermsScreen';
import OnboardingScreen from './screens/OnboardingScreen';
import TabIcon from './components/TabIcon';
import {colors} from './theme';
import {isOnboardingDone} from './storage';

const Stack = createNativeStackNavigator();
const Tab = createBottomTabNavigator();

function HomeStack() {
  return (
    <Stack.Navigator screenOptions={{headerShown: false, contentStyle: {backgroundColor: colors.bg}}}>
      <Stack.Screen name="HomeMain" component={HomeScreen} />
      <Stack.Screen name="Log" component={LogScreen} />
      <Stack.Screen name="ObservationDetail" component={ObservationDetailScreen} />
      <Stack.Screen name="Calendar" component={CalendarScreen} />
      <Stack.Screen name="Species" component={SpeciesScreen} />
    </Stack.Navigator>
  );
}

function AtlasStack() {
  return (
    <Stack.Navigator screenOptions={{headerShown: false, contentStyle: {backgroundColor: colors.bg}}}>
      <Stack.Screen name="AtlasMain" component={AtlasScreen} />
      <Stack.Screen name="ObservationDetail" component={ObservationDetailScreen} />
      <Stack.Screen name="Species" component={SpeciesScreen} />
      <Stack.Screen name="Log" component={LogScreen} />
    </Stack.Navigator>
  );
}

function GuideStack() {
  return (
    <Stack.Navigator screenOptions={{headerShown: false, contentStyle: {backgroundColor: colors.bg}}}>
      <Stack.Screen name="GuideMain" component={GuideScreen} />
      <Stack.Screen name="GuideDetail" component={GuideDetailScreen} />
      <Stack.Screen name="Log" component={LogScreen} />
    </Stack.Navigator>
  );
}

function ProfileStack() {
  return (
    <Stack.Navigator screenOptions={{headerShown: false, contentStyle: {backgroundColor: colors.bg}}}>
      <Stack.Screen name="ProfileMain" component={ProfileScreen} />
      <Stack.Screen name="Settings" component={SettingsScreen} />
      <Stack.Screen name="Privacy" component={PrivacyScreen} />
      <Stack.Screen name="Terms" component={TermsScreen} />
    </Stack.Navigator>
  );
}

const navTheme = {
  ...DefaultTheme,
  colors: {...DefaultTheme.colors, background: colors.bg, card: colors.card},
};

function MainTabs() {
  const insets = useSafeAreaInsets();
  return (
    <Tab.Navigator
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: colors.card,
          borderTopWidth: StyleSheet.hairlineWidth,
          borderTopColor: colors.border,
          height: 56 + insets.bottom,
          paddingBottom: insets.bottom + 4,
          paddingTop: 8,
        },
        tabBarActiveTintColor: colors.primary,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarLabelStyle: {fontSize: 11, fontWeight: '600'},
      }}>
      <Tab.Screen
        name="HomeTab"
        component={HomeStack}
        options={{
          tabBarLabel: '首页',
          tabBarIcon: ({focused, color}) => <TabIcon name="home-outline" focused={focused} color={color} />,
        }}
      />
      <Tab.Screen
        name="AtlasTab"
        component={AtlasStack}
        options={{
          tabBarLabel: '图鉴',
          tabBarIcon: ({focused, color}) => <TabIcon name="albums-outline" focused={focused} color={color} />,
        }}
      />
      <Tab.Screen
        name="GuideTab"
        component={GuideStack}
        options={{
          tabBarLabel: '图志',
          tabBarIcon: ({focused, color}) => <TabIcon name="book-outline" focused={focused} color={color} />,
        }}
      />
      <Tab.Screen
        name="ProfileTab"
        component={ProfileStack}
        options={{
          tabBarLabel: '我的',
          tabBarIcon: ({focused, color}) => <TabIcon name="person-outline" focused={focused} color={color} />,
        }}
      />
    </Tab.Navigator>
  );
}

function PlantAppInner() {
  const [ready, setReady] = useState(false);
  const [showOnboarding, setShowOnboarding] = useState(false);

  useEffect(() => {
    isOnboardingDone().then(done => {
      setShowOnboarding(!done);
      setReady(true);
    });
  }, []);

  if (!ready) return null;

  return (
    <GestureHandlerRootView style={{flex: 1}}>
      <SafeAreaProvider>
        <StatusBar barStyle="light-content" backgroundColor={colors.primary} />
        {showOnboarding ? (
          <OnboardingScreen onDone={() => setShowOnboarding(false)} />
        ) : (
          <NavigationContainer theme={navTheme}>
            <MainTabs />
          </NavigationContainer>
        )}
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

export default function PlantApp() {
  return <PlantAppInner />;
}
