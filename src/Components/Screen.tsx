import React, { SFC } from 'react';
import { SafeAreaView, StyleSheet, ViewProps } from 'react-native';

const Screen: SFC<ViewProps> = ({ style, ...rest }) => (
  <SafeAreaView {...rest} style={[styles.container, style]} />
);

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#FFF',
  },
});

export default Screen;
