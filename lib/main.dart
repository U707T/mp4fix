import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/app/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  await controller.init();
  runApp(Mp4FixApp(controller: controller));
}
