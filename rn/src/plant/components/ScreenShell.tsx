import React from 'react';
import {View, StyleSheet} from 'react-native';
import {colors} from '../theme';

type Props = {
  children: React.ReactNode;
  style?: object;
};

export default function ScreenShell({children, style}: Props) {
  return <View style={[styles.outer, style]}>{children}</View>;
}

const styles = StyleSheet.create({
  outer: {flex: 1, width: '100%', backgroundColor: colors.bg},
});
