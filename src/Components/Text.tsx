import React, { SFC } from 'react';
import { Text as RNText, StyleSheet, TextProps } from 'react-native';

export const getFontSizeStyle = (fontSize: number) => ({
  fontSize,
  lineHeight: fontSize * 1.2,
});

const Text: SFC<TextProps> = ({ children, style, ...rest }) => (
  <RNText {...rest} style={[styles.default, style]}>
    {children}
  </RNText>
);

export const Title: SFC<TextProps> = ({ children, style, ...rest }) => (
  <Text {...rest} style={[styles.title, style]}>
    {children}
  </Text>
);

export const Note: SFC<TextProps> = ({ children, style, ...rest }) => (
  <Text {...rest} style={[styles.note, style]}>
    {children}
  </Text>
);

const styles = StyleSheet.create({
  default: {
    ...getFontSizeStyle(16),
    color: '#252C3B',
  },
  title: {
    ...getFontSizeStyle(20),
    marginBottom: 15,
  },
  note: {
    ...getFontSizeStyle(10),
    color: '#6E7A90',
  },
});

export default Text;
