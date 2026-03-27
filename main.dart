
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ==========================================
// 1. CONSTANTS & CONFIGURATION
// ==========================================

const int ROWS = 8;
const int COLS = 7;
const int WIN_SCORE = 6;
const int LAYER_DELAY_MS = 80;
const int STEP_DURATION_MS = 240;

// Colors matching CSS theme
const Color bgColor = Color(0xFF1A1A1A);
const Color boardBg = Color(0xFF2A2235);
const Color cellColor = Color(0xFF584A73);
const Color cellHoverColor = Color(0xFF6A5A87);
const Color borderColor = Color(0xFF3B314A);
const Color selectedColor = Color(0xFF9370DB);
const Color availableColor = Color(0xFFD8B4FE);
const Color swapColor = Color(0xFFFFB3C1);
const Color metalBaseColor = Color(0xFF9AA0B8);
const Color metalHighlightColor = Color(0xFFEDEAF9);
const Color metalShadowColor = Color(0xFF454B61);

class TeamTheme {
  final Color color;
  final Color glow;
  const TeamTheme(this.color, this.glow);
}

const TeamTheme purpleTheme = TeamTheme(Color(0xFFA87CFF), Color(0xFFEAD8FF));
const TeamTheme orangeTheme = TeamTheme(Color(0xFFFF6B6B), Color(0xFFFFD6D6));

// AI Evaluation Weights
const Map<String, int> BASE_WEIGHTS = {
  'WIN': 1000000, 'POINT': 15000, 'CAPTURE_CIRCLE': 8000, 'PIECE_P': 100,
  'PIECE_D': 350, 'PIECE_C': 600, 'ADVANCEMENT': 20, 'CENTER_CONTROL': 30,
  'THREATENED': -200, 'IMMOBILIZE_ENEMY': 500, 'IMMOBILIZED_SELF': -400,
};

final Map<String, int> PURPLE_WEIGHTS = {
  ...BASE_WEIGHTS, 'CENTER_CONTROL': 40, 'PIECE_P': 110
};
final Map<String, int> ORANGE_WEIGHTS = {
  ...BASE_WEIGHTS, 'PIECE_D': 370, 'THREATENED': -250
};

// ==========================================
// 2. DATA MODELS
// ==========================================

class PieceConfig {
  final String id;
  final String type;
  final List<String> directions;
  final List<String> jumpDirections;

  const PieceConfig({
    required this.id, required this.type, required this.directions, this.jumpDirections = const [],
  });
}

const List<PieceConfig> PIECE_CONFIGS =[
  PieceConfig(id: 'PR', type: 'P', directions: ['w', 'se']),
  PieceConfig(id: 'PL', type: 'P', directions: ['e', 'sw']),
  PieceConfig(id: 'PX', type: 'P', directions: ['nw', 'ne', 'sw', 'se']),
  PieceConfig(id: 'DP', type: 'D', directions: ['n', 'w', 'e']),
  PieceConfig(id: 'DT', type: 'D', directions:['n', 'nw', 'ne', 's']),
  PieceConfig(id: 'DN', type: 'D', directions:['n', 's', 'w', 'e'], jumpDirections: ['w', 'e']),
  PieceConfig(id: 'C', type: 'C', directions: ['n', 'sw', 'se']),
];

final Map<String, PieceConfig> CONFIG_BY_ID = {
  for (var config in PIECE_CONFIGS) config.id: config
};

class SetupPos {
  final String id; final int row; final int col;
  const SetupPos(this.id, this.row, this.col);
}

const List<SetupPos> PURPLE_SETUP =[
  SetupPos('PR', 6, 0), SetupPos('PL', 6, 1), SetupPos('PR', 6, 2), SetupPos('PX', 6, 3),
  SetupPos('PL', 6, 4), SetupPos('PR', 6, 5), SetupPos('PL', 6, 6), SetupPos('DP', 7, 0),
  SetupPos('DT', 7, 1), SetupPos('DN', 7, 2), SetupPos('C', 7, 3), SetupPos('DN', 7, 4),
  SetupPos('DT', 7, 5), SetupPos('DP', 7, 6),
];

const List<SetupPos> ORANGE_SETUP =[
  SetupPos('PL', 1, 0), SetupPos('PR', 1, 1), SetupPos('PL', 1, 2), SetupPos('PX', 1, 3),
  SetupPos('PR', 1, 4), SetupPos('PL', 1, 5), SetupPos('PR', 1, 6), SetupPos('DP', 0, 0),
  SetupPos('DT', 0, 1), SetupPos('DN', 0, 2), SetupPos('C', 0, 3), SetupPos('DN', 0, 4),
  SetupPos('DT', 0, 5), SetupPos('DP', 0, 6),
];

class PieceData {
  String id;
  String type;
  String team;
  int rotation;
  int immobilizedTurn;
  int uid;

  PieceData({
    required this.id, required this.type, required this.team,
    this.rotation = 0, this.immobilizedTurn = 0, required this.uid,
  });

  PieceData clone() => PieceData(
      id: id, type: type, team: team, rotation: rotation,
      immobilizedTurn: immobilizedTurn, uid: uid);
}

class Coordinate {
  final int r; final int c;
  const Coordinate(this.r, this.c);
  @override bool operator ==(Object other) => other is Coordinate && r == other.r && c == other.c;
  @override int get hashCode => Object.hash(r, c);
}

class MoveAction {
  final Coordinate from; final Coordinate to;
  final bool isSwap; final int preMoveRotation;
  int scoreVal;
  MoveAction({required this.from, required this.to, required this.isSwap, required this.preMoveRotation, this.scoreVal = 0});
}

class GameSnapshot {
  final List<List<PieceData?>> board;
  final int purpleScore;
  final int orangeScore;
  final int turnCount;
  final String currentTurn;
  final List<String> fullNotation;

  GameSnapshot({
    required this.board, required this.purpleScore, required this.orangeScore,
    required this.turnCount, required this.currentTurn, required this.fullNotation,
  });
}

// ==========================================
// 3. GAME LOGIC & PATHFINDING (BFS)
// ==========================================

class GameLogic {
  static Map<String, List<int>> getUnitVectors(String team) {
    if (team == 'orange') return {'up': [1, 0], 'down': [-1, 0], 'left': [0, 1], 'right': [0, -1]};
    return {'up': [-1, 0], 'down': [1, 0], 'left': [0, -1], 'right': [0, 1]};
  }

  static Map<String, List<int>> getRotatedUnitVectors(String team, int rotation) {
    var base = getUnitVectors(team);
    List<List<int>> vectors = [base['up']!, base['right']!, base['down']!, base['left']!];
    int shift = ((rotation / 90) % 4).floor();
    return {
      'up': vectors[shift], 'right': vectors[(shift + 1) % 4],
      'down': vectors[(shift + 2) % 4], 'left': vectors[(shift + 3) % 4]
    };
  }

  static List<Coordinate> getImmediateMoves(int r, int c, PieceData piece, [int? customRotation]) {
    int rotation = customRotation ?? piece.rotation;
    var v = getRotatedUnitVectors(piece.team, rotation);
    List<Coordinate> moves =[];

    void push(List<int> d) {
      int rr = r + d[0], cc = c + d[1];
      if (rr >= 0 && rr < ROWS && cc >= 0 && cc < COLS) moves.add(Coordinate(rr, cc));
    }
    List<int> add(List<int> a, List<int> b) => [a[0] + b[0], a[1] + b[1]];
    List<int> mul(List<int> a, int k) => [a[0] * k, a[1] * k];

    String t = piece.id;
    if (t == 'PR') { push(v['left']!); push(add(v['right']!, v['down']!)); }
    else if (t == 'PL') { push(v['right']!); push(add(v['left']!, v['down']!)); }
    else if (t == 'PX') { push(add(v['right']!, v['up']!)); push(add(v['right']!, v['down']!)); push(add(v['left']!, v['up']!)); push(add(v['left']!, v['down']!)); }
    else if (t == 'DP') { push(v['up']!); push(mul(v['up']!, 2)); push(v['left']!); push(v['right']!); }
    else if (t == 'DT') { push(v['up']!); push(add(v['up']!, v['left']!)); push(add(v['up']!, v['right']!)); push(v['down']!); }
    else if (t == 'DN') { push(v['up']!); push(v['down']!); push(mul(v['left']!, 2)); push(mul(v['right']!, 2)); }
    else if (t == 'C') { push(v['up']!); push(add(v['down']!, v['left']!)); push(add(v['down']!, v['right']!)); }

    return moves;
  }

  static List<List<Set<Coordinate>>> getAccessibleHighlightLayers(List<List<PieceData?>> board, int sr, int sc,[int? customRot]) {
    PieceData originPiece = board[sr][sc]!;
    Coordinate originCoord = Coordinate(sr, sc);
    List<List<Set<Coordinate>>> layers =[];
    Set<Coordinate> visitedPieces = {originCoord};
    Set<Coordinate> visitedPositions = {};
    Set<Coordinate> currentLayerPieces = {originCoord};

    while (currentLayerPieces.isNotEmpty) {
      Set<Coordinate> emptyLayer = {};
      Set<Coordinate> occupiedLayer = {};
      Set<Coordinate> nextLayerPieces = {};

      for (var curr in currentLayerPieces) {
        PieceData currPiece = board[curr.r][curr.c]!;
        bool isOrigin = curr.r == sr && curr.c == sc;
        var immed = getImmediateMoves(curr.r, curr.c, currPiece, isOrigin ? customRot : null);

        for (var target in immed) {
          if (target == originCoord || visitedPositions.contains(target)) continue;
          PieceData? targetData = board[target.r][target.c];

          if (targetData != null) {
            occupiedLayer.add(target);
            if (targetData.team == originPiece.team && !visitedPieces.contains(target)) {
              visitedPieces.add(target);
              nextLayerPieces.add(target);
            }
          } else if (!isOrigin) {
            emptyLayer.add(target);
          }
        }
      }

      if (emptyLayer.isNotEmpty || occupiedLayer.isNotEmpty) {
        layers.add([emptyLayer, occupiedLayer]);
      }
      visitedPositions.addAll(emptyLayer);
      visitedPositions.addAll(occupiedLayer);
      currentLayerPieces = nextLayerPieces;
    }
    return layers;
  }

  static List<Coordinate>? findMovementPath(List<List<PieceData?>> board, int sr, int sc, int dr, int dc,[int? customRot]) {
    PieceData startPiece = board[sr][sc]!;
    List<Map<String, dynamic>> queue = [{'pos': Coordinate(sr, sc), 'path':[Coordinate(sr, sc)]}];
    Set<Coordinate> visited = {Coordinate(sr, sc)};

    while (queue.isNotEmpty) {
      var current = queue.removeAt(0);
      Coordinate pos = current['pos'];
      List<Coordinate> path = List<Coordinate>.from(current['path']);
      PieceData currentPiece = board[pos.r][pos.c]!;
      bool isStart = pos.r == sr && pos.c == sc;

      var moves = getImmediateMoves(pos.r, pos.c, currentPiece, isStart ? customRot : null);
      for (var target in moves) {
        if (target.r == dr && target.c == dc) {
          path.add(target);
          return path;
        }
        PieceData? targetP = board[target.r][target.c];
        if (targetP != null && targetP.team == startPiece.team && !visited.contains(target)) {
          visited.add(target);
          List<Coordinate> newPath = List<Coordinate>.from(path)..add(target);
          queue.add({'pos': target, 'path': newPath});
        }
      }
    }
    return [Coordinate(sr, sc), Coordinate(dr, dc)]; // Fallback
  }
}

// ==========================================
// 4. ALPHA-BETA MINIMAX AI ENGINE
// ==========================================

class AIEngine {
  static List<List<PieceData?>> cloneBoard(List<List<PieceData?>> board) {
    return board.map((row) => row.map((p) => p?.clone()).toList()).toList();
  }

  static List<MoveAction> generateMoves(List<List<PieceData?>> board, String team, int turnCount) {
    List<MoveAction> moves =[];
    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        PieceData? piece = board[r][c];
        if (piece == null || piece.team != team || (piece.immobilizedTurn > turnCount)) continue;

        List<int> rotations = (piece.type == 'D') ?[0, 90, 180, 270] : [piece.rotation];

        for (int rot in rotations) {
          List<Coordinate> queue = [Coordinate(r, c)];
          Set<Coordinate> visited = {Coordinate(r, c)};
          int head = 0;

          while (head < queue.length) {
            Coordinate curr = queue[head++];
            PieceData currentP = board[curr.r][curr.c]!;
            int effRot = (curr.r == r && curr.c == c) ? rot : currentP.rotation;
            var neighbors = GameLogic.getImmediateMoves(curr.r, curr.c, currentP, effRot);

            for (var target in neighbors) {
              PieceData? targetP = board[target.r][target.c];

              if (targetP != null) {
                if (targetP.team != team) {
                  moves.add(MoveAction(from: Coordinate(r, c), to: target, isSwap: true, preMoveRotation: rot));
                } else if (!visited.contains(target)) {
                  visited.add(target);
                  queue.add(target);
                }
              } else if (!visited.contains(target) && !(curr.r == r && curr.c == c)) {
                moves.add(MoveAction(from: Coordinate(r, c), to: target, isSwap: false, preMoveRotation: rot));
              }
            }
          }
        }
      }
    }

    for (var m in moves) {
      int val = 0;
      if (m.isSwap) val += 1000;
      int dist = (team == 'purple') ? (7 - m.to.r) : m.to.r;
      val += dist;
      m.scoreVal = val;
    }
    moves.sort((a, b) => b.scoreVal.compareTo(a.scoreVal));
    return moves;
  }

  static int evaluateBoard(List<List<PieceData?>> board, String team, int purpleScore, int orangeScore, int turnCount) {
    Map<String, int> w = (team == 'purple') ? PURPLE_WEIGHTS : ORANGE_WEIGHTS;
    int score = 0;
    int myScore = team == 'orange' ? orangeScore : purpleScore;
    int oppScore = team == 'orange' ? purpleScore : orangeScore;

    if (myScore >= WIN_SCORE) return w['WIN']!;
    if (oppScore >= WIN_SCORE) return -w['WIN']!;
    score += (myScore - oppScore) * w['POINT']!;

    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        PieceData? p = board[r][c];
        if (p == null) continue;

        bool isMe = p.team == team;
        int val = p.type == 'P' ? w['PIECE_P']! : (p.type == 'D' ? w['PIECE_D']! : w['PIECE_C']!);
        int posVal = 0;

        if (p.type == 'P') {
          int steps = p.team == 'purple' ? (6 - r) : (r - 1);
          posVal += steps * steps * w['ADVANCEMENT']!;
          if (!isMe && ((p.team == 'purple' && r == 1) || (p.team == 'orange' && r == 6))) {
            score -= 5000;
          }
        }

        if (c >= 2 && c <= 4) posVal += w['CENTER_CONTROL']!;
        if (p.immobilizedTurn > turnCount) {
          posVal += isMe ? w['IMMOBILIZED_SELF']! : w['IMMOBILIZE_ENEMY']!;
        }

        if (isMe) score += val + posVal;
        else score -= (val + posVal);
      }
    }
    return score;
  }

  static Map<String, dynamic> applyMoveSim(List<List<PieceData?>> board, MoveAction m, int turnCount, int pScore, int oScore) {
    PieceData movingP = board[m.from.r][m.from.c]!.clone();
    movingP.rotation = m.preMoveRotation;
    PieceData? targetP = board[m.to.r][m.to.c]?.clone();

    int scoreAdd = 0;
    bool removeMoving = false;
    bool removeTarget = false;

    if (m.isSwap && movingP.type == 'C' && targetP?.type == 'C') {
      removeTarget = true;
      scoreAdd += 2;
    }

    int promoRow = movingP.team == 'purple' ? 0 : ROWS - 1;
    if (movingP.type == 'P' && m.to.r == promoRow) {
      removeMoving = true;
      if (movingP.id != 'PX') scoreAdd = scoreAdd > 0 ? scoreAdd : 1;
    }

    if (movingP.team == 'purple') pScore += scoreAdd;
    else oScore += scoreAdd;

    board[m.from.r][m.from.c] = null;
    if (m.isSwap && !removeTarget) {
      targetP!.immobilizedTurn = turnCount + 2;
      board[m.from.r][m.from.c] = targetP;
    }
    board[m.to.r][m.to.c] = removeMoving ? null : movingP;

    return {'pScore': pScore, 'oScore': oScore};
  }

  static int nodesVisited = 0;

  static int minimax(List<List<PieceData?>> board, int depth, int alpha, int beta, bool isMaximizing, int turnCount, int pScore, int oScore, String botTeam, int startTime, int maxTime) {
    nodesVisited++;
    if (nodesVisited % 500 == 0 && (DateTime.now().millisecondsSinceEpoch - startTime > maxTime)) {
      return evaluateBoard(board, botTeam, pScore, oScore, turnCount);
    }

    String currentTeam = isMaximizing ? botTeam : (botTeam == 'purple' ? 'orange' : 'purple');

    if (depth == 0 || pScore >= WIN_SCORE || oScore >= WIN_SCORE) {
      return evaluateBoard(board, botTeam, pScore, oScore, turnCount);
    }

    var moves = generateMoves(board, currentTeam, turnCount);
    if (moves.isEmpty) return evaluateBoard(board, botTeam, pScore, oScore, turnCount);

    if (isMaximizing) {
      int maxEval = -99999999;
      for (var m in moves) {
        var nextB = cloneBoard(board);
        var res = applyMoveSim(nextB, m, turnCount, pScore, oScore);
        int ev = minimax(nextB, depth - 1, alpha, beta, false, turnCount + 1, res['pScore'], res['oScore'], botTeam, startTime, maxTime);
        maxEval = math.max(maxEval, ev);
        alpha = math.max(alpha, ev);
        if (beta <= alpha) break;
      }
      return maxEval;
    } else {
      int minEval = 99999999;
      for (var m in moves) {
        var nextB = cloneBoard(board);
        var res = applyMoveSim(nextB, m, turnCount, pScore, oScore);
        int ev = minimax(nextB, depth - 1, alpha, beta, true, turnCount + 1, res['pScore'], res['oScore'], botTeam, startTime, maxTime);
        minEval = math.min(minEval, ev);
        beta = math.min(beta, ev);
        if (beta <= alpha) break;
      }
      return minEval;
    }
  }
}

// ==========================================
// 5. CUSTOM VISUAL ENGINE (CUSTOMPAINTER)
// ==========================================

class PiecePainter extends CustomPainter {
  final PieceData piece;
  final bool isSelected;
  final bool isImmobilized;
  final double scale;

  PiecePainter({required this.piece, this.isSelected = false, this.isImmobilized = false, this.scale = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (isImmobilized) {
      canvas.saveLayer(Offset.zero & size, Paint()..colorFilter = const ColorFilter.matrix([
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0,      0,      0,      1, 0,
      ]));
    }

    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final PieceConfig config = CONFIG_BY_ID[piece.id]!;
    final TeamTheme theme = piece.team == 'purple' ? purpleTheme : orangeTheme;

    canvas.translate(cx, cy);
    int baseRot = piece.team == 'orange' ? 180 : 0;
    canvas.rotate((baseRot + piece.rotation) * math.pi / 180);
    canvas.scale(scale);
    canvas.translate(-cx, -cy);

    Paint connectorPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, cy - size.height * 0.42), Offset(cx, cy),[metalShadowColor, const Color(0xFF2A2E37)]
      )
      ..style = PaintingStyle.fill;

    // Draw Connectors
    for (String dir in config.directions) {
      canvas.save();
      canvas.translate(cx, cy);
      double angle = _getAngle(dir);
      canvas.rotate(angle);
      canvas.drawRRect(RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(0, -size.height * 0.21), width: size.width * 0.06, height: size.height * 0.42),
          const Radius.circular(2)), connectorPaint);
      canvas.restore();
    }

    // Draw Nodes
    for (String dir in config.directions) {
      canvas.save();
      canvas.translate(cx, cy);
      double angle = _getAngle(dir);
      canvas.rotate(angle);
      
      bool isJump = config.jumpDirections.contains(dir);
      bool isPower = piece.id == 'DP' && dir == 'n';
      
      Paint nodeBg = Paint();
      Paint nodeBorder = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0;
      
      if (isSelected && !isJump && !isPower) {
        nodeBg.shader = ui.Gradient.radial(Offset(0, -size.height * 0.44), size.width * 0.08,[theme.glow, theme.color]);
        nodeBorder.color = theme.glow;
        _drawGlow(canvas, Offset(0, -size.height * 0.44), size.width * 0.08, theme.color, 10);
      } else if (isSelected && isJump) {
        nodeBg.shader = ui.Gradient.radial(Offset(0, -size.height * 0.44), size.width * 0.08, [metalShadowColor, Colors.black]);
        nodeBorder.color = theme.glow;
        _drawGlow(canvas, Offset(0, -size.height * 0.44), size.width * 0.08, theme.color, 10);
      } else if (isSelected && isPower) {
        nodeBg.shader = ui.Gradient.radial(Offset(0, -size.height * 0.44), size.width * 0.08,[Colors.white, theme.glow, theme.color], [0, 0.55, 1]);
        nodeBorder.color = Colors.white;
        _drawGlow(canvas, Offset(0, -size.height * 0.44), size.width * 0.08, theme.color, 10);
      } else {
        nodeBg.shader = ui.Gradient.radial(Offset(0, -size.height * 0.44), size.width * 0.08, [metalHighlightColor, metalBaseColor]);
        nodeBorder.color = metalShadowColor;
      }

      canvas.drawCircle(Offset(0, -size.height * 0.44), size.width * 0.085, nodeBg);
      canvas.drawCircle(Offset(0, -size.height * 0.44), size.width * 0.085, nodeBorder);
      canvas.restore();
    }

    // Draw Centerpiece
    double cSize = piece.type == 'D' ? 0.25 : (piece.type == 'C' ? 0.40 : 0.20);
    Rect cRect = Rect.fromCenter(center: Offset(cx, cy), width: size.width * cSize, height: size.height * cSize);
    
    Paint centerBg = Paint()..shader = ui.Gradient.linear(cRect.topLeft, cRect.bottomRight,[metalHighlightColor, metalBaseColor]);
    Paint centerBorder = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0..color = metalShadowColor;

    canvas.save();
    if (piece.type == 'D') {
      canvas.translate(cx, cy);
      canvas.rotate(45 * math.pi / 180);
      canvas.translate(-cx, -cy);
      canvas.drawRect(cRect, centerBg);
      canvas.drawRect(cRect, centerBorder);
    } else {
      canvas.drawCircle(Offset(cx, cy), size.width * cSize / 2, centerBg);
      canvas.drawCircle(Offset(cx, cy), size.width * cSize / 2, centerBorder);
    }
    canvas.restore();

    // Draw Gem
    double gSize = cSize * 0.6;
    Rect gRect = Rect.fromCenter(center: Offset(cx, cy), width: size.width * gSize, height: size.height * gSize);
    Paint gemBg = Paint()..shader = ui.Gradient.radial(Offset(cx - gRect.width*0.2, cy - gRect.height*0.2), gRect.width,[theme.glow, theme.color]);

    if (isSelected) {
      _drawGlow(canvas, Offset(cx, cy), gRect.width / 2, theme.color, 12);
    }

    canvas.save();
    if (piece.type == 'D') {
      canvas.translate(cx, cy);
      canvas.rotate(45 * math.pi / 180);
      canvas.translate(-cx, -cy);
      canvas.drawRRect(RRect.fromRectAndRadius(gRect, const Radius.circular(2)), gemBg);
    } else {
      canvas.drawCircle(Offset(cx, cy), size.width * gSize / 2, gemBg);
    }
    canvas.restore();

    if (isImmobilized) canvas.restore();
  }

  double _getAngle(String dir) {
    const map = {'n': 0.0, 'ne': 45.0, 'e': 90.0, 'se': 135.0, 's': 180.0, 'sw': 225.0, 'w': 270.0, 'nw': 315.0};
    return map[dir]! * math.pi / 180;
  }

  void _drawGlow(Canvas canvas, Offset center, double radius, Color color, double blurRadius) {
    Paint glow = Paint()
      ..color = color
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, blurRadius);
    canvas.drawCircle(center, radius, glow);
  }

  @override
  bool shouldRepaint(PiecePainter oldDelegate) => 
      oldDelegate.piece != piece || oldDelegate.isSelected != isSelected || oldDelegate.isImmobilized != isImmobilized || oldDelegate.scale != scale;
}



// END OF PART 1 - Type "continue" for Part 2

// ==========================================
// 6. MAIN FLUTTER APP & STATE CONTROLLER
// ==========================================

void main() {
  runApp(const GyroadApp());
}

class GyroadApp extends StatelessWidget {
  const GyroadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GYROAD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: bgColor,
        fontFamily: 'Georgia', // Matching CSS serif
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic),
        ),
      ),
      home: const GyroadGame(),
    );
  }
}

class GyroadGame extends StatefulWidget {
  const GyroadGame({super.key});

  @override
  State<GyroadGame> createState() => _GyroadGameState();
}

class _GyroadGameState extends State<GyroadGame> with TickerProviderStateMixin {
  // Game State
  late List<List<PieceData?>> boardState;
  int purpleScore = 0;
  int orangeScore = 0;
  int turnCount = 1;
  String currentTurn = 'purple';
  bool gameOver = false;
  String? winnerMessage;

  // Interaction State
  Coordinate? selectedCell;
  Set<Coordinate> availableCells = {};
  Set<Coordinate> swapAvailableCells = {};
  bool isAnimating = false;
  bool isInteractionLocked = false;
  
  // Rotation State
  bool isRotating = false;
  int rotationsThisTurn = 0;
  int? rotatedPieceId;
  int originalRotation = 0;
  int visualRotation = 0;

  // History & Modes
  List<GameSnapshot> moveHistory = [];
  List<String> fullNotation =[];
  String gameMode = 'bot'; // '2-player', 'bot', 'bot-vs-bot', 'explorer'
  String botTeam = 'orange';
  
  // AI Settings
  int depthPurple = 3;
  int timePurple = 1000;
  int depthOrange = 3;
  int timeOrange = 1000;

  // Explorer State
  List<String> explorerMoves =[];
  int explorerIndex = 0;
  bool showExplorerModal = false;
  bool showSettingsModal = false;
  final TextEditingController _explorerController = TextEditingController();

  int pieceUidCounter = 0;

  @override
  void initState() {
    super.initState();
    _initBoard();
  }

  void _initBoard() {
    boardState = List.generate(ROWS, (_) => List.generate(COLS, (_) => null));
    pieceUidCounter = 0;

    for (var pos in PURPLE_SETUP) {
      boardState[pos.row][pos.col] = PieceData(
        id: pos.id, type: CONFIG_BY_ID[pos.id]!.type, team: 'purple', uid: pieceUidCounter++
      );
    }
    for (var pos in ORANGE_SETUP) {
      boardState[pos.row][pos.col] = PieceData(
        id: pos.id, type: CONFIG_BY_ID[pos.id]!.type, team: 'orange', uid: pieceUidCounter++, rotation: 0 // Base rotation handled visually
      );
    }

    if (gameMode == 'bot' && currentTurn == botTeam) {
      _executeBotTurn();
    } else if (gameMode == 'bot-vs-bot') {
      _executeBotTurn();
    }
  }

  void resetGame() {
    setState(() {
      selectedCell = null;
      isAnimating = false;
      isInteractionLocked = false;
      isRotating = false;
      currentTurn = 'purple';
      turnCount = 1;
      purpleScore = 0;
      orangeScore = 0;
      gameOver = false;
      winnerMessage = null;
      rotationsThisTurn = 0;
      rotatedPieceId = null;
      moveHistory.clear();
      availableCells.clear();
      swapAvailableCells.clear();

      if (gameMode != 'explorer' || explorerIndex == 0) {
        fullNotation.clear();
      }

      _initBoard();
    });
  }

  void _saveState() {
    moveHistory.add(GameSnapshot(
      board: AIEngine.cloneBoard(boardState),
      purpleScore: purpleScore, orangeScore: orangeScore,
      turnCount: turnCount, currentTurn: currentTurn,
      fullNotation: List.from(fullNotation),
    ));
    if (moveHistory.length > 100) moveHistory.removeAt(0);
  }

  void handleUndo() {
    if (isAnimating || gameOver || moveHistory.isEmpty) return;
    
    GameSnapshot? targetSnapshot;
    if (gameMode == 'explorer') {
      targetSnapshot = moveHistory.removeLast();
    } else if (gameMode == 'bot') {
      if (moveHistory.length >= 2) {
        moveHistory.removeLast();
        targetSnapshot = moveHistory.removeLast();
      } else if (moveHistory.length == 1) {
        targetSnapshot = moveHistory.removeLast();
      }
    } else {
      targetSnapshot = moveHistory.removeLast();
    }

    if (targetSnapshot != null) {
      setState(() {
        boardState = AIEngine.cloneBoard(targetSnapshot!.board);
        purpleScore = targetSnapshot.purpleScore;
        orangeScore = targetSnapshot.orangeScore;
        turnCount = targetSnapshot.turnCount;
        currentTurn = targetSnapshot.currentTurn;
        fullNotation = List.from(targetSnapshot.fullNotation);
        rotationsThisTurn = 0;
        rotatedPieceId = null;
        _clearHighlights();
      });
    }
  }

  void _clearHighlights() {
    availableCells.clear();
    swapAvailableCells.clear();
    isRotating = false;
    selectedCell = null;
  }

  String _rcToCoord(int r, int c) => String.fromCharCode(97 + c) + (8 - r).toString();
  Coordinate _coordToRC(String coord) => Coordinate(8 - int.parse(coord[1]), coord.codeUnitAt(0) - 97);

  Future<void> _executeMove(Coordinate from, Coordinate to, bool isSwap, int? preMoveRotation) async {
    if (isAnimating) return;
    _saveState();

    PieceData movingPiece = boardState[from.r][from.c]!;
    PieceData? targetPiece = isSwap ? boardState[to.r][to.c] : null;

    if (gameMode != 'explorer') {
      String pieceID = movingPiece.id;
      String startCoord = _rcToCoord(from.r, from.c);
      String endCoord = _rcToCoord(to.r, to.c);
      String action = isSwap ? 'x' : '-';
      String rotStr = (preMoveRotation != null && preMoveRotation != movingPiece.rotation) ? 'R$preMoveRotation' : '';
      fullNotation.add('$pieceID$startCoord$rotStr$action$endCoord');
    }

    setState(() {
      isAnimating = true;
      isInteractionLocked = true;
      if (preMoveRotation != null) movingPiece.rotation = preMoveRotation;
      _clearHighlights();
      
      // Let AnimatedPositioned handle the smooth transition
      boardState[from.r][from.c] = null;
      boardState[to.r][to.c] = movingPiece;
      
      if (isSwap && targetPiece != null) {
        boardState[from.r][from.c] = targetPiece;
      }
    });

    // Wait for the step duration mapping (simulating CSS transitions)
    await Future.delayed(const Duration(milliseconds: STEP_DURATION_MS));

    int scoreToAdd = 0;
    bool removeMoving = false;
    bool removeTarget = false;

    if (isSwap && movingPiece.type == 'C' && targetPiece?.type == 'C') {
      removeTarget = true;
      scoreToAdd += 2;
    }

    int promoRow = movingPiece.team == 'purple' ? 0 : ROWS - 1;
    if (movingPiece.type == 'P' && to.r == promoRow) {
      removeMoving = true;
      if (movingPiece.id != 'PX') scoreToAdd = scoreToAdd > 0 ? scoreToAdd : 1;
    }

    setState(() {
      if (removeMoving) boardState[to.r][to.c] = null;
      if (isSwap && removeTarget) boardState[from.r][from.c] = null;
      
      if (isSwap && !removeTarget && targetPiece != null && movingPiece.team != targetPiece.team) {
        targetPiece.immobilizedTurn = turnCount + 2;
      }

      if (currentTurn == 'purple') purpleScore += scoreToAdd;
      else orangeScore += scoreToAdd;

      _checkWinCondition();
      isAnimating = false;
      if (!gameOver) isInteractionLocked = false;
    });

    if (!gameOver) await _switchTurn();
  }

  void _checkWinCondition() {
    if (purpleScore >= WIN_SCORE) _endGame('Purple');
    if (orangeScore >= WIN_SCORE) _endGame('Orange');
  }

  void _endGame(String winner) {
    setState(() {
      gameOver = true;
      isInteractionLocked = true;
      winnerMessage = '$winner Wins!';
    });
    if (gameMode == 'bot-vs-bot') {
      Future.delayed(const Duration(seconds: 4), resetGame);
    }
  }

  Future<void> _switchTurn() async {
    if (gameOver) return;
    setState(() {
      turnCount++;
      currentTurn = currentTurn == 'purple' ? 'orange' : 'purple';
      rotationsThisTurn = 0;
      rotatedPieceId = null;

      // Un-immobilize pieces
      for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
          PieceData? p = boardState[r][c];
          if (p != null && p.team == currentTurn && p.immobilizedTurn > 0 && turnCount >= p.immobilizedTurn) {
            p.immobilizedTurn = 0;
          }
        }
      }
    });

    if (!_hasAnyValidMoves(currentTurn)) {
      _endGame(currentTurn == 'purple' ? 'Orange' : 'Purple');
      return;
    }

    if (gameMode == 'bot' && currentTurn == botTeam) {
      await _executeBotTurn();
    } else if (gameMode == 'bot-vs-bot') {
      await _executeBotTurn();
    }
  }

  bool _hasAnyValidMoves(String team) {
    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        PieceData? p = boardState[r][c];
        if (p != null && p.team == team && (p.immobilizedTurn == 0 || turnCount >= p.immobilizedTurn)) {
          var layers = GameLogic.getAccessibleHighlightLayers(boardState, r, c);
          if (layers.isNotEmpty) return true;
        }
      }
    }
    return false;
  }

  Future<void> _executeBotTurn() async {
    setState(() { isInteractionLocked = true; });
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (gameOver) return;

    int depth = currentTurn == 'purple' ? depthPurple : depthOrange;
    int maxTime = currentTurn == 'purple' ? timePurple : timeOrange;
    int startTime = DateTime.now().millisecondsSinceEpoch;
    AIEngine.nodesVisited = 0;

    var moves = AIEngine.generateMoves(boardState, currentTurn, turnCount);
    if (moves.isEmpty) {
      await _switchTurn();
      return;
    }

    MoveAction bestMove = moves[0];
    int bestValue = -99999999;
    int alpha = -99999999;
    int beta = 99999999;

    for (var m in moves) {
      if (DateTime.now().millisecondsSinceEpoch - startTime > maxTime) break;
      var nextB = AIEngine.cloneBoard(boardState);
      var res = AIEngine.applyMoveSim(nextB, m, turnCount, purpleScore, orangeScore);
      int moveVal = AIEngine.minimax(nextB, depth - 1, alpha, beta, false, turnCount + 1, res['pScore'], res['oScore'], currentTurn, startTime, maxTime);
      
      if (moveVal > bestValue) {
        bestValue = moveVal;
        bestMove = m;
      }
      alpha = math.max(alpha, bestValue);
    }

    await _executeMove(bestMove.from, bestMove.to, bestMove.isSwap, bestMove.preMoveRotation);
  }

  void handleCellClick(int r, int c) {
    if (isInteractionLocked || gameOver || (gameMode == 'bot' && currentTurn == botTeam) || gameMode == 'bot-vs-bot' || gameMode == 'explorer') return;

    Coordinate clicked = Coordinate(r, c);

    if (isRotating) {
      if (selectedCell == clicked) {
        setState(() => visualRotation = (visualRotation + 90) % 360);
      }
      return;
    }

    if (selectedCell != null && (availableCells.contains(clicked) || swapAvailableCells.contains(clicked))) {
      bool isSwap = swapAvailableCells.contains(clicked);
      _executeMove(selectedCell!, clicked, isSwap, null);
      return;
    }

    PieceData? clickedPiece = boardState[r][c];
    if (clickedPiece != null) {
      if (clickedPiece.team != currentTurn || (clickedPiece.immobilizedTurn > 0 && turnCount < clickedPiece.immobilizedTurn)) return;

      if (selectedCell == clicked) {
        setState(() => _clearHighlights());
      } else {
        setState(() {
          _clearHighlights();
          selectedCell = clicked;
          if (clickedPiece.type == 'D' && rotationsThisTurn < 2 && clickedPiece.uid != rotatedPieceId) {
            // Show rotate UI handles via Stack
          }
          _revealHighlights(r, c);
        });
      }
    } else {
      setState(() => _clearHighlights());
    }
  }

  void _revealHighlights(int r, int c) async {
    var layers = GameLogic.getAccessibleHighlightLayers(boardState, r, c);
    for (var layer in layers) {
      await Future.delayed(const Duration(milliseconds: LAYER_DELAY_MS));
      if (!mounted || selectedCell?.r != r || selectedCell?.c != c) break;
      setState(() {
        availableCells.addAll(layer[0]);
        swapAvailableCells.addAll(layer[1]);
      });
    }
  }

  void _enterRotationMode() {
    if (selectedCell == null) return;
    PieceData p = boardState[selectedCell!.r][selectedCell!.c]!;
    if (rotationsThisTurn >= 2 || p.uid == rotatedPieceId) return;

    setState(() {
      isRotating = true;
      originalRotation = p.rotation;
      visualRotation = p.rotation;
      availableCells.clear();
      swapAvailableCells.clear();
    });
  }

  void _exitRotationMode(bool confirm) {
    if (!isRotating || selectedCell == null) return;
    PieceData p = boardState[selectedCell!.r][selectedCell!.c]!;

    setState(() {
      if (confirm && visualRotation != originalRotation) {
        rotationsThisTurn++;
        rotatedPieceId = p.uid;
        p.rotation = visualRotation;
      }
      isRotating = false;
      _revealHighlights(selectedCell!.r, selectedCell!.c);
    });
  }

  void _loadExplorerGame() {
    String input = _explorerController.text;
    RegExp regex = RegExp(r'([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])');
    var matches = regex.allMatches(input);
    
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid moves found.')));
      return;
    }

    setState(() {
      explorerMoves = matches.map((m) => m.group(0)!).toList();
      gameMode = 'explorer';
      explorerIndex = 0;
      showExplorerModal = false;
      resetGame();
    });
  }

  Future<void> _nextExplorerMove() async {
    if (isAnimating || explorerIndex >= explorerMoves.length) return;
    
    String moveStr = explorerMoves[explorerIndex];
    RegExp regex = RegExp(r'^([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])$');
    var match = regex.firstMatch(moveStr);
    if (match == null) return;

    Coordinate from = _coordToRC(match.group(2)!);
    Coordinate to = _coordToRC(match.group(5)!);
    int? rot = match.group(3) != null ? int.parse(match.group(3)!) : null;
    bool isSwap = match.group(4) == 'x';

    setState(() { fullNotation.add(moveStr); });
    await _executeMove(from, to, isSwap, rot);
    setState(() { explorerIndex++; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children:[
          // Background Gradient matching web bg
          Container(color: bgColor),

          SafeArea(
            child: Column(
              children:[
                _buildScoreBars(),
                Expanded(
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double padding = 20;
                        double maxWidth = constraints.maxWidth - padding * 2;
                        double maxHeight = constraints.maxHeight - padding * 2;
                        double cellSize = math.min(maxWidth / COLS, maxHeight / ROWS);
                        double boardWidth = cellSize * COLS;
                        double boardHeight = cellSize * ROWS;

                        return SizedBox(
                          width: boardWidth,
                          height: boardHeight,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children:[
                              // Board Grid Background
                              Container(
                                decoration: BoxDecoration(
                                  color: boardBg,
                                  border: Border.all(color: currentTurn == 'purple' ? purpleTheme.color : orangeTheme.color, width: 3),
                                  boxShadow: const[BoxShadow(color: Colors.black54, blurRadius: 20)],
                                ),
                                child: GridView.builder(
                                  physics: const NeverScrollableScrollPhysics(),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: COLS,
                                    mainAxisSpacing: 0, crossAxisSpacing: 0,
                                  ),
                                  itemCount: ROWS * COLS,
                                  itemBuilder: (context, index) {
                                    int r = index ~/ COLS; int c = index % COLS;
                                    Coordinate coord = Coordinate(r, c);
                                    bool isSelected = selectedCell == coord;
                                    bool isAvail = availableCells.contains(coord);
                                    bool isSwap = swapAvailableCells.contains(coord);

                                    return GestureDetector(
                                      onTap: () => handleCellClick(r, c),
                                      child: Container(
                                        margin: const EdgeInsets.all(2), // Simulate CSS gap
                                        decoration: BoxDecoration(
                                          color: isSelected ? selectedColor : (isAvail ? availableColor : (isSwap ? swapColor : cellColor)),
                                          boxShadow: isSelected || isAvail || isSwap ?[
                                            BoxShadow(color: isSelected ? selectedColor : (isSwap ? swapColor : availableColor), blurRadius: 15)
                                          ] : null,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

                              // Animated Pieces
                              ..._buildPieces(cellSize),

                              // Win Message Overlay
                              if (gameOver)
                                Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 30),
                                    decoration: BoxDecoration(
                                      color: const Color(0xF11A1A1A),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: borderColor, width: 2),
                                    ),
                                    child: Text(
                                      winnerMessage!,
                                      style: TextStyle(
                                        fontSize: 40,
                                        color: Colors.white,
                                        shadows:[BoxShadow(color: winnerMessage!.contains('Purple') ? purpleTheme.color : orangeTheme.color, blurRadius: 15).scale(1)]
                                      ),
                                    ),
                                  ),
                                ),

                              // Controls Overlay (Left side)
                              if (selectedCell != null && !isInteractionLocked)
                                Positioned(
                                  left: -60,
                                  top: (currentTurn == 'orange') ? 0 : null,
                                  bottom: (currentTurn == 'purple') ? 0 : null,
                                  child: _buildControls(),
                                )
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                _buildNotationPanel(),
              ],
            ),
          ),

          // Floating Buttons
          Positioned(
            bottom: 15, left: MediaQuery.of(context).size.width / 2 - 25,
            child: FloatingActionButton(
              heroTag: 'settings', backgroundColor: const Color(0xFF6A5A87),
              child: const Icon(Icons.settings),
              onPressed: () => setState(() => showSettingsModal = true),
            ),
          ),
          if (gameMode != 'bot-vs-bot' && gameMode != 'explorer' && moveHistory.isNotEmpty)
            Positioned(
              bottom: 15, right: 20,
              child: FloatingActionButton(
                heroTag: 'undo', backgroundColor: const Color(0xFF6A5A87),
                child: const Icon(Icons.undo),
                onPressed: handleUndo,
              ),
            ),

          // Modals
          if (showSettingsModal) _buildSettingsModal(),
          if (showExplorerModal) _buildExplorerModal(),
        ],
      ),
    );
  }

  List<Widget> _buildPieces(double cellSize) {
    List<Widget> pieces =[];
    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        PieceData? p = boardState[r][c];
        if (p != null) {
          bool isSelected = selectedCell?.r == r && selectedCell?.c == c;
          int rotationToDraw = (isRotating && isSelected) ? visualRotation : p.rotation;
          
          pieces.add(
            AnimatedPositioned(
              key: ValueKey(p.uid),
              duration: const Duration(milliseconds: STEP_DURATION_MS),
              curve: Curves.easeInOut,
              left: c * cellSize,
              top: r * cellSize,
              width: cellSize,
              height: cellSize,
              child: IgnorePointer( // Let grid capture clicks
                child: Padding(
                  padding: const EdgeInsets.all(2.0),
                  child: CustomPaint(
                    painter: PiecePainter(
                      piece: p..rotation = rotationToDraw,
                      isSelected: isSelected,
                      isImmobilized: p.immobilizedTurn > turnCount,
                      scale: isSelected ? 1.05 : 1.0,
                    ),
                  ),
                ),
              ),
            )
          );
        }
      }
    }
    return pieces;
  }

  Widget _buildControls() {
    PieceData p = boardState[selectedCell!.r][selectedCell!.c]!;
    if (p.type != 'D' || rotationsThisTurn >= 2 || p.uid == rotatedPieceId) return const SizedBox();

    return Column(
      children:[
        if (!isRotating)
          IconButton(
            icon: const Icon(Icons.rotate_right, color: Colors.white, size: 30),
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF6A5A87), shape: const RoundedRectangleBorder()),
            onPressed: _enterRotationMode,
          ),
        if (isRotating) ...[
          IconButton(
            icon: const Icon(Icons.check, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: selectedColor, shape: const RoundedRectangleBorder()),
            onPressed: () => _exitRotationMode(true),
          ),
          const SizedBox(height: 5),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF6A5A87), shape: const RoundedRectangleBorder()),
            onPressed: () => _exitRotationMode(false),
          ),
        ]
      ],
    );
  }

  Widget _buildScoreBars() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children:[
          Row(children: List.generate(WIN_SCORE, (i) => Container(
            width: 25, height: 10, margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              border: Border.all(color: purpleTheme.color, width: 2),
              color: i < purpleScore ? purpleTheme.color : Colors.transparent,
              boxShadow: i < purpleScore ?[BoxShadow(color: purpleTheme.color, blurRadius: 5)] : null,
            ),
          ))),
          Row(children: List.generate(WIN_SCORE, (i) => Container(
            width: 25, height: 10, margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              border: Border.all(color: orangeTheme.color, width: 2),
              color: i < orangeScore ? orangeTheme.color : Colors.transparent,
              boxShadow: i < orangeScore ?[BoxShadow(color: orangeTheme.color, blurRadius: 5)] : null,
            ),
          ))),
        ],
      ),
    );
  }

  Widget _buildNotationPanel() {
    String text = 'Game Start';
    if (fullNotation.isNotEmpty) {
      List<String> pairs =[];
      for (int i = 0; i < fullNotation.length; i += 2) {
        String pair = '${(i ~/ 2) + 1}. ${fullNotation[i]}';
        if (i + 1 < fullNotation.length) pair += ' ${fullNotation[i + 1]}';
        pairs.add(pair);
      }
      text = pairs.join('   ');
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 80, left: 10, right: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children:[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true, // Always show latest
              child: Text(text, style: const TextStyle(fontFamily: 'monospace', color: Colors.white70)),
            ),
          ),
          const SizedBox(width: 10),
          if (gameMode != 'explorer') ...[
            _actionBtn('Copy', () => Clipboard.setData(ClipboardData(text: text))),
            const SizedBox(width: 5),
            _actionBtn('Explorer', () => setState(() => showExplorerModal = true)),
          ] else ...[
            _actionBtn('<', () => handleUndo()),
            const SizedBox(width: 5),
            _actionBtn('>', _nextExplorerMove),
            const SizedBox(width: 5),
            _actionBtn('Exit', () => setState(() { gameMode = 'bot'; resetGame(); })),
          ]
        ],
      ),
    );
  }

  Widget _actionBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors:[Color(0xFF6A5A87), Color(0xFF3B314A)]),
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildSettingsModal() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Container(
          width: 350,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xFF1A1A1C), border: Border.all(color: borderColor)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children:[
              const Text('Game Mode', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 10),
              _modeBtn('2-Player (Local)', '2-player'),
              _modeBtn('1-Player (vs Bot)', 'bot'),
              _modeBtn('Bot vs Bot', 'bot-vs-bot'),
              const Divider(color: Colors.white24, height: 30),
              const Text('AI Depth & Time', style: TextStyle(color: selectedColor)),
              _sliderRow('Purple Depth: $depthPurple', depthPurple.toDouble(), 1, 5, (v) => setState(() => depthPurple = v.toInt())),
              _sliderRow('Purple Time (ms): $timePurple', timePurple.toDouble(), 100, 3000, (v) => setState(() => timePurple = v.toInt())),
              _sliderRow('Orange Depth: $depthOrange', depthOrange.toDouble(), 1, 5, (v) => setState(() => depthOrange = v.toInt())),
              _sliderRow('Orange Time (ms): $timeOrange', timeOrange.toDouble(), 100, 3000, (v) => setState(() => timeOrange = v.toInt())),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]),
                onPressed: () => setState(() => showSettingsModal = false),
                child: const Text('Close', style: TextStyle(color: Colors.white)),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeBtn(String label, String mode) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: gameMode == mode ? selectedColor : const Color(0xFF3B314A),
            shape: const RoundedRectangleBorder(),
          ),
          onPressed: () {
            setState(() { gameMode = mode; if (mode == 'bot') botTeam = 'orange'; showSettingsModal = false; resetGame(); });
          },
          child: Text(label, style: const TextStyle(color: Colors.white, fontFamily: 'Georgia', fontStyle: FontStyle.italic)),
        ),
      ),
    );
  }

  Widget _sliderRow(String label, double val, double min, double max, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:[
        Text(label, style: const TextStyle(fontSize: 12)),
        Slider(value: val, min: min, max: max, activeColor: selectedColor, onChanged: onChanged),
      ],
    );
  }

  Widget _buildExplorerModal() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Container(
          width: 350, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xFF1A1A1C), border: Border.all(color: borderColor)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children:[
              const Text('Game Explorer', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 10),
              TextField(
                controller: _explorerController,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Paste notation here...',
                  hintStyle: TextStyle(color: Colors.white38),
                  filled: true, fillColor: Colors.black54,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 15),
              SizedBox(width: double.infinity, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: selectedColor, shape: const RoundedRectangleBorder()),
                onPressed: _loadExplorerGame,
                child: const Text('Load Game', style: TextStyle(color: Colors.white)),
              )),
              const SizedBox(height: 5),
              SizedBox(width: double.infinity, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800], shape: const RoundedRectangleBorder()),
                onPressed: () => setState(() => showExplorerModal = false),
                child: const Text('Cancel', style: TextStyle(color: Colors.white)),
              )),
            ],
          ),
        ),
      ),
    );
  }
}
