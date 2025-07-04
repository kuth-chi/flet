import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../flet_app_services.dart';
import '../flet_control_backend.dart';
import '../flet_server.dart';
import '../models/control.dart';
import '../utils/numbers.dart';
import '../utils/platform.dart';
import '../utils/strings.dart';
import 'flet_store_mixin.dart';

class FilePickerResultEvent {
  final String? path;
  final List<FilePickerFile>? files;
  final String? error;

  FilePickerResultEvent(
      {required this.path, required this.files, required this.error});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'files': files?.map((f) => f.toJson()).toList(),
        'error': error
      };
}

class FilePickerFile {
  final int id;
  final String name;
  final String? path;
  final int size;

  FilePickerFile(
      {required this.id,
      required this.name,
      required this.path,
      required this.size});

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'id': id, 'name': name, 'path': path, 'size': size};
}

class FilePickerUploadFile {
  final int id;
  final String name;
  final String uploadUrl;
  final String method;

  FilePickerUploadFile(
      {required this.id,
      required this.name,
      required this.uploadUrl,
      required this.method});
}

class FilePickerUploadProgressEvent {
  final String name;
  final double? progress;
  final String? error;

  FilePickerUploadProgressEvent(
      {required this.name, required this.progress, required this.error});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'file_name': name,
        'progress': progress,
        'error': error
      };
}

class FilePickerControl extends StatefulWidget {
  final Control? parent;
  final Control control;
  final Widget? nextChild;
  final FletControlBackend backend;

  const FilePickerControl(
      {super.key,
      required this.parent,
      required this.control,
      required this.nextChild,
      required this.backend});

  @override
  State<FilePickerControl> createState() => _FilePickerControlState();
}

class _FilePickerControlState extends State<FilePickerControl>
    with FletStoreMixin {
  String? _state;
  String? _upload;
  String? _path;
  List<PlatformFile>? _files;
  String? _error;

  @override
  Widget build(BuildContext context) {
    debugPrint("FilePicker build: ${widget.control.id}");

    return withPageArgs((context, pageArgs) {
      var state = widget.control.attrString("state");
      var upload = widget.control.attrString("upload");
      var dialogTitle = widget.control.attrString("dialogTitle");
      var fileName = widget.control.attrString("fileName");
      var initialDirectory = widget.control.attrString("initialDirectory");
      var allowMultiple = widget.control.attrBool("allowMultiple", false)!;
      var allowedExtensions =
          parseStringList(widget.control, "allowedExtensions");
      var srcBytesBase64 = widget.control.attrString("srcBytes");
      FileType fileType = FileType.values.firstWhere(
          (m) =>
              m.name.toLowerCase() ==
              widget.control.attrString("fileType", "")!.toLowerCase(),
          orElse: () => FileType.any);
      if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
        fileType = FileType.custom;
      }

      debugPrint("FilePicker _state: $_state, state: $state");

      resetDialogState() {
        _state = null;
        widget.backend.updateControlState(widget.control.id, {"state": ""});
      }

      sendEvent() {
        if (defaultTargetPlatform != TargetPlatform.windows ||
            !isDesktopPlatform()) {
          resetDialogState();
        }

        widget.backend.triggerControlEvent(
          widget.control.id,
          "result",
          json.encode(FilePickerResultEvent(
              path: _path,
              files: _files?.asMap().entries.map((entry) {
                PlatformFile f = entry.value;
                return FilePickerFile(
                  id: entry.key, // use entry's index as id
                  name: f.name,
                  path: kIsWeb ? null : f.path,
                  size: f.size,
                );
              }).toList(),
              error: _error)),
        );
      }

      if (_state != state) {
        _path = null;
        _files = null;
        _error = null;
        _state = state;

        if (isDesktopPlatform() &&
            defaultTargetPlatform == TargetPlatform.windows) {
          resetDialogState();
        }

        // pickFiles
        if (state?.toLowerCase() == "pickfiles") {
          FilePicker.platform
              .pickFiles(
                  dialogTitle: dialogTitle,
                  initialDirectory: initialDirectory,
                  lockParentWindow: true,
                  type: fileType,
                  allowedExtensions: allowedExtensions,
                  allowMultiple: allowMultiple,
                  withData: false,
                  withReadStream: true)
              .then((FilePickerResult? result) {
            debugPrint("pickFiles() completed");
            _files = result?.files;
            sendEvent();
          });
        }
        // saveFile
        else if (state?.toLowerCase() == "savefile" && !kIsWeb) {
          if ((isAndroidPlatform() || isiOSPlatform()) &&
              srcBytesBase64 == null) {
            _error =
                '"src_bytes" is required on Android & iOS when saving a file.';
            sendEvent();
          } else {
            FilePicker.platform
                .saveFile(
                    dialogTitle: dialogTitle,
                    fileName: fileName != null || !isiOSPlatform()
                        ? fileName
                        : "new-file",
                    initialDirectory: initialDirectory,
                    lockParentWindow: true,
                    type: fileType,
                    allowedExtensions: allowedExtensions,
                    bytes: srcBytesBase64 != null
                        ? base64Decode(srcBytesBase64)
                        : null)
                .then((result) {
              debugPrint("saveFile() completed");
              _path = result;
              sendEvent();
            });
          }
        }
        // getDirectoryPath
        else if (state?.toLowerCase() == "getdirectorypath" && !kIsWeb) {
          FilePicker.platform
              .getDirectoryPath(
            dialogTitle: dialogTitle,
            initialDirectory: initialDirectory,
            lockParentWindow: true,
          )
              .then((result) {
            debugPrint("getDirectoryPath() completed");
            _path = result;
            sendEvent();
          });
        }
      }

      // upload files
      if (_upload != upload && upload != null && _files != null) {
        _upload = upload;
        uploadFiles(
            upload, FletAppServices.of(context).server, pageArgs.pageUri!);
      }

      return widget.nextChild ?? const SizedBox.shrink();
    });
  }

  Future uploadFiles(String filesJson, FletServer server, Uri pageUri) async {
    var uj = json.decode(filesJson);
    var uploadFiles = (uj as List).map((u) => FilePickerUploadFile(
        id: parseInt(u["id"], -1)!, // -1 = invalid
        name: u["name"],
        uploadUrl: u["upload_url"],
        method: u["method"]));

    for (var uf in uploadFiles) {
      var file = ((uf.id >= 0 && uf.id < _files!.length)
              ? _files![uf.id]
              : null) // by id
          ??
          _files!.firstWhereOrNull((f) => f.name == uf.name); // by name

      if (file != null) {
        try {
          await uploadFile(
              file, server, getFullUploadUrl(pageUri, uf.uploadUrl), uf.method);
          _files!.remove(file); // Remove the uploaded file
        } catch (e) {
          sendProgress(server, file.name, null, e.toString());
        }
      } else {
        debugPrint("Error: File '${uf.name}' (id: ${uf.id}) not found.");
      }
    }
  }

  Future uploadFile(PlatformFile file, FletServer server, String uploadUrl,
      String method) async {
    final fileReadStream = file.readStream;
    if (fileReadStream == null) {
      throw Exception('Cannot read file from null stream');
    }
    debugPrint("Uploading ${file.name}");
    final streamedRequest = http.StreamedRequest(method, Uri.parse(uploadUrl))
      ..headers.addAll({
        //'Cache-Control': 'no-cache',
      });
    streamedRequest.contentLength = file.size;

    // send 0%
    sendProgress(server, file.name, 0, null);

    double lastSent = 0; // send every 10%
    double progress = 0;
    int bytesSent = 0;
    fileReadStream.listen((chunk) async {
      //debugPrint(chunk.length);
      streamedRequest.sink.add(chunk);
      bytesSent += chunk.length;
      progress = bytesSent / file.size;
      if (progress >= lastSent) {
        lastSent += 0.1;
        if (progress != 1.0) {
          sendProgress(server, file.name, progress, null);
        }
      }
    }, onDone: () {
      streamedRequest.sink.close();
    });

    var streamedResponse = await streamedRequest.send();
    var response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode < 200 || response.statusCode > 204) {
      sendProgress(server, file.name, null,
          "Upload endpoint returned code ${response.statusCode}: ${response.body}");
    } else {
      // send 100%
      sendProgress(server, file.name, progress, null);
    }
  }

  void sendProgress(
      FletServer server, String name, double? progress, String? error) {
    widget.backend.triggerControlEvent(
        widget.control.id,
        "upload",
        json.encode(FilePickerUploadProgressEvent(
            name: name, progress: progress, error: error)));
  }

  String getFullUploadUrl(Uri pageUri, String uploadUrl) {
    Uri uploadUri = Uri.parse(uploadUrl);
    if (!uploadUri.hasAuthority) {
      return Uri(
              scheme: pageUri.scheme,
              host: pageUri.host,
              port: pageUri.port,
              path: uploadUri.path,
              query: uploadUri.query)
          .toString();
    } else {
      return uploadUrl;
    }
  }
}
