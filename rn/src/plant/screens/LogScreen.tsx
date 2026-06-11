import React, {useEffect, useState} from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  Alert,
  Image,
} from 'react-native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {launchImageLibrary} from 'react-native-image-picker';
import Ionicons from 'react-native-vector-icons/Ionicons';
import {colors, seasons, habitats} from '../theme';
import {addObservation, loadObservations, updateObservation} from '../storage';
import type {Habitat, Observation, Season} from '../types';
import {PLANT_IMAGES} from '../assets/images';

export default function LogScreen({route, navigation}: {route: any; navigation: any}) {
  const insets = useSafeAreaInsets();
  const preset = route.params || {};
  const editId = preset.editId as string | undefined;
  const [plantName, setPlantName] = useState(preset.plantName || '');
  const [location, setLocation] = useState('');
  const [note, setNote] = useState('');
  const [season, setSeason] = useState<Season>('夏季');
  const [habitat, setHabitat] = useState<Habitat>('公园');
  const [imageUri, setImageUri] = useState<string | undefined>();
  const [imageAsset, setImageAsset] = useState<string | undefined>(preset.referenceId);
  const [referenceId, setReferenceId] = useState<string | undefined>(preset.referenceId);
  const presetAsset = preset.referenceId as string | undefined;

  useEffect(() => {
    if (!editId) return;
    loadObservations().then(list => {
      const item = list.find(o => o.id === editId);
      if (!item) return;
      setPlantName(item.plantName);
      setLocation(item.location);
      setNote(item.note === '（无补充说明）' ? '' : item.note);
      setSeason(item.season);
      setHabitat(item.habitat);
      setImageUri(item.imageUri);
      setImageAsset(item.imageAsset);
      setReferenceId(item.referenceId);
    });
  }, [editId]);

  const previewSource = imageUri
    ? {uri: imageUri}
    : imageAsset && PLANT_IMAGES[imageAsset]
      ? PLANT_IMAGES[imageAsset]
      : presetAsset && !editId && PLANT_IMAGES[presetAsset]
        ? PLANT_IMAGES[presetAsset]
        : null;

  const pickImage = async () => {
    const result = await launchImageLibrary({mediaType: 'photo', selectionLimit: 1, quality: 0.8});
    if (result.assets?.[0]?.uri) {
      setImageUri(result.assets[0].uri);
      setImageAsset(undefined);
    }
  };

  const handleSave = async () => {
    if (!plantName.trim()) {
      Alert.alert('提示', '请填写植物名称');
      return;
    }
    if (!location.trim()) {
      Alert.alert('提示', '请填写观察地点');
      return;
    }
    const payload = {
      plantName: plantName.trim(),
      referenceId,
      location: location.trim(),
      habitat,
      season,
      note: note.trim() || '（无补充说明）',
      imageUri,
      imageAsset: imageUri ? undefined : imageAsset || presetAsset,
    };
    if (editId) {
      await updateObservation(editId, payload);
      Alert.alert('已保存', '观察记录已更新', [{text: '好的', onPress: () => navigation.goBack()}]);
    } else {
      const item: Observation = {
        id: `obs-${Date.now()}`,
        date: new Date().toISOString().slice(0, 10),
        ...payload,
      };
      await addObservation(item);
      Alert.alert('已保存', '观察记录已加入你的图鉴', [{text: '好的', onPress: () => navigation.goBack()}]);
    }
  };

  return (
    <View style={[styles.container, {paddingTop: insets.top}]}>
      <TouchableOpacity style={styles.back} onPress={() => navigation.goBack()}>
        <Text style={styles.backText}>‹ 取消</Text>
      </TouchableOpacity>
      <ScrollView contentContainerStyle={{padding: 24, paddingBottom: insets.bottom + 40}} keyboardShouldPersistTaps="handled">
        <Text style={styles.title}>{editId ? '编辑观察' : '新建观察'}</Text>

        <Field label="观察照片（可选）">
          <TouchableOpacity style={styles.photoBox} onPress={pickImage} activeOpacity={0.85}>
            {previewSource ? (
              <Image source={previewSource} style={styles.photoPreview} />
            ) : (
              <View style={styles.photoPlaceholder}>
                <Ionicons name="camera-outline" size={32} color={colors.primaryLight} />
                <Text style={styles.photoHint}>从相册选择照片</Text>
              </View>
            )}
          </TouchableOpacity>
        </Field>

        <Field label="植物名称">
          <TextInput style={styles.input} value={plantName} onChangeText={setPlantName} placeholder="如：银杏" placeholderTextColor={colors.textMuted} />
        </Field>
        <Field label="观察地点">
          <TextInput style={styles.input} value={location} onChangeText={setLocation} placeholder="如：滨河公园东侧" placeholderTextColor={colors.textMuted} />
        </Field>

        <Field label="季节">
          <ChipRow options={seasons as unknown as string[]} value={season} onChange={v => setSeason(v as Season)} />
        </Field>
        <Field label="生境">
          <ChipRow options={habitats as unknown as string[]} value={habitat} onChange={v => setHabitat(v as Habitat)} />
        </Field>

        <Field label="观察笔记">
          <TextInput
            style={[styles.input, styles.multiline]}
            value={note}
            onChangeText={setNote}
            placeholder="记录叶形、颜色、气味或生长状态…"
            placeholderTextColor={colors.textMuted}
            multiline
          />
        </Field>

        <TouchableOpacity style={styles.saveBtn} onPress={handleSave}>
          <Text style={styles.saveText}>{editId ? '保存修改' : '保存记录'}</Text>
        </TouchableOpacity>
      </ScrollView>
    </View>
  );
}

function Field({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      {children}
    </View>
  );
}

function ChipRow({options, value, onChange}: {options: string[]; value: string; onChange: (v: string) => void}) {
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{gap: 8}}>
      {options.map(o => (
        <TouchableOpacity key={o} style={[styles.chip, value === o && styles.chipActive]} onPress={() => onChange(o)}>
          <Text style={[styles.chipText, value === o && styles.chipTextActive]}>{o}</Text>
        </TouchableOpacity>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: colors.bg},
  back: {paddingHorizontal: 20, paddingVertical: 8},
  backText: {fontSize: 17, color: colors.primaryLight},
  title: {fontSize: 24, fontWeight: '700', color: colors.text, marginBottom: 20},
  photoBox: {
    backgroundColor: colors.card,
    borderRadius: 14,
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  photoPreview: {width: '100%', height: 180},
  photoPlaceholder: {height: 140, alignItems: 'center', justifyContent: 'center', gap: 8},
  photoHint: {fontSize: 13, color: colors.textMuted},
  field: {marginBottom: 18},
  label: {fontSize: 14, fontWeight: '600', color: colors.textSecondary, marginBottom: 8},
  input: {
    backgroundColor: colors.card,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 15,
    color: colors.text,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  multiline: {minHeight: 100, textAlignVertical: 'top'},
  chip: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 16,
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.border,
  },
  chipActive: {backgroundColor: colors.primaryLight, borderColor: colors.primaryLight},
  chipText: {fontSize: 13, color: colors.textSecondary},
  chipTextActive: {color: '#fff', fontWeight: '600'},
  saveBtn: {
    marginTop: 12,
    backgroundColor: colors.primary,
    paddingVertical: 15,
    borderRadius: 14,
    alignItems: 'center',
  },
  saveText: {color: '#fff', fontSize: 16, fontWeight: '600'},
});
