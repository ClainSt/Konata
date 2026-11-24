import 'package:pointycastle/asn1.dart';

class ASN1TaggedObject extends ASN1Sequence {
  // }

  ASN1TaggedObject(ASN1Object obj, {int? tag, int tagNo = 0})
      : super(
            tag: (tag ?? ASN1Tags.TAGGED | ASN1Tags.CONSTRUCTED) | tagNo,
            elements: [obj]);

  ///
  /// 解析含显式或隐式上下文标签的 ASN.1 编码对象。
  ///
  ASN1TaggedObject.fromBytes(super.encodedBytes) : super.fromBytes() {
    elements = [];
    var parser = ASN1Parser(valueBytes);
    if (parser.hasNext()) {
      elements!.add(parser.nextObject());
    }
  }

  ASN1Object? get obj => elements?.firstOrNull;
}
