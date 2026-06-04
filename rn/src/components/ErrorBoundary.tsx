import React, {Component, type ErrorInfo, type ReactNode} from 'react';
import {View, Text, TouchableOpacity, StyleSheet, ScrollView} from 'react-native';
import {Colors} from '../app/theme';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = {hasError: false, error: null};

  static getDerivedStateFromError(error: Error): State {
    return {hasError: true, error};
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[ErrorBoundary]', error, info.componentStack);
  }

  handleReset = () => {
    this.setState({hasError: false, error: null});
  };

  render() {
    if (this.state.hasError) {
      return (
        <View style={styles.container}>
          <Text style={styles.emoji}>⚠️</Text>
          <Text style={styles.title}>出了点问题</Text>
          <Text style={styles.subtitle}>应用遇到了未预期的错误</Text>
          <ScrollView style={styles.errorBox} contentContainerStyle={styles.errorContent}>
            <Text style={styles.errorText}>
              {this.state.error?.message || '未知错误'}
            </Text>
          </ScrollView>
          <TouchableOpacity style={styles.button} onPress={this.handleReset}>
            <Text style={styles.buttonText}>重试</Text>
          </TouchableOpacity>
        </View>
      );
    }

    return this.props.children;
  }
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: Colors.background,
    padding: 32,
  },
  emoji: {fontSize: 48, marginBottom: 16},
  title: {
    fontSize: 20,
    fontWeight: '700',
    color: Colors.textPrimary,
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 14,
    color: Colors.textSecondary,
    marginBottom: 20,
  },
  errorBox: {
    maxHeight: 120,
    width: '100%',
    backgroundColor: 'rgba(0,0,0,0.04)',
    borderRadius: 8,
    marginBottom: 24,
  },
  errorContent: {padding: 12},
  errorText: {
    fontSize: 12,
    color: Colors.error,
    fontFamily: 'Menlo',
  },
  button: {
    backgroundColor: Colors.primary,
    paddingHorizontal: 36,
    paddingVertical: 12,
    borderRadius: 22,
  },
  buttonText: {
    color: Colors.white,
    fontSize: 16,
    fontWeight: '600',
  },
});
