import React from 'react';
import {View, Image, StyleSheet, Text} from 'react-native';
import {colors} from '../theme';
import {resolveImageSource} from '../assets/images';

type Props = {
  item: {plantName: string; imageUri?: string; imageAsset?: string; referenceId?: string};
  size?: number;
};

export default function PlantThumb({item, size = 56}: Props) {
  const src = resolveImageSource({
    imageUri: item.imageUri,
    imageAsset: item.imageAsset || item.referenceId,
  });

  if (src) {
    return (
      <Image
        source={src}
        style={{width: size, height: size, borderRadius: size * 0.22}}
      />
    );
  }

  return (
    <View style={[styles.fallback, {width: size, height: size, borderRadius: size * 0.22}]}>
      <Text style={[styles.char, {fontSize: size * 0.36}]}>{item.plantName.charAt(0)}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  fallback: {
    backgroundColor: colors.accentSoft,
    alignItems: 'center',
    justifyContent: 'center',
  },
  char: {fontWeight: '700', color: colors.primary},
});
