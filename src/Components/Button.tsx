import React, { SFC } from 'react';
import {
  StyleSheet,
  TouchableOpacity,
  TouchableOpacityProps,
} from 'react-native';
import Text, { getFontSizeStyle } from './Text';

const Button: SFC<TouchableOpacityProps> = ({ children, style, ...rest }) => (
  <TouchableOpacity {...rest} style={[styles.default, style]}>
    <Text style={styles.text}>{children}</Text>
  </TouchableOpacity>
);

const styles = StyleSheet.create({
  default: {
    backgroundColor: '#475062',
    paddingHorizontal: 35,
    paddingVertical: 15,
    borderRadius: 8,
  },
  text: {
    ...getFontSizeStyle(16),
    fontWeight: 'bold',
    color: '#FFF',
    textAlign: 'center',
  },
});

export default Button;
