import React from 'react';
import {View, StyleSheet} from 'react-native';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {colors} from '../theme';

type Props = {
  name: string;
  focused: boolean;
  color: string;
};

export default function TabIcon({name, focused, color}: Props) {
  return (
    <View style={[styles.wrap, focused && styles.active]}>
      <Ionicons name={name} size={22} color={color} />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    width: 40,
    height: 32,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 16,
  },
  active: {
    backgroundColor: colors.accentSoft + '80',
  },
});
