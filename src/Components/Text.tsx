import React, { SFC } from 'react';
import { Text as RNText, StyleSheet, TextProps } from 'react-native';

const getFontSizeStyle = (fontSize: number) => ({
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

const styles = StyleSheet.create({
  default: {
    ...getFontSizeStyle(16),
  },
  title: {
    ...getFontSizeStyle(20),
    marginBottom: 10,
  },
});

export default Text;
