import 'dart:collection';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GyroadApp());
}

// ==========================================
// CONSTANTS & CONFIGURATION
// ==========================================

const int configRows = 8;
const int configCols = 7;
const int winScore = 6;

enum Team { purple, orange }
enum PieceShape { point, diamond, circle }
enum Dir { n, ne, e, se, s, sw, w, nw }

class AppColors {
  static const bg = Color(0xFF1A1A1A);
  static const boardBg = Color(0xFF2A2235);
  static const cell = Color(0xFF584A73);
  static const cellHover = Color(0xFF6A5A87);
  static const border = Color(0xFF3B314A);
  static const purpleEnergy = Color(0xFFA87CFF);
  static const purpleGlow = Color(0xFFEAD8FF);
  static const orangeEnergy = Color(0xFFFF6B6B);
  static const orangeGlow = Color(0xFFFFD6D6);
  static const metalBase = Color(0xFF9AA0B8);
  static const metalHighlight = Color(0xFFEDEAF9);
  static const metalShadow = Color(0xFF454B61);
}

const Map<String, int> baseWeights = {
  'WIN': 1000000, 'POINT': 15000, 'CAPTURE_CIRCLE': 8000,
  'PIECE_P': 100, 'PIECE_D': 350, 'PIECE_C': 600,
  'ADVANCEMENT': 20, 'CENTER_CONTROL': 30, 'THREATENED': -200,
  'IMMOBILIZE_ENEMY': 500, 'IMMOBILIZED_SELF': -400
};

// ==========================================
// MODELS
// ==========================================

class PieceConfig {
  final String id;
  final PieceShape type;
  final List<Dir> dirs;
  final List<Dir> jumpDirs;
  const PieceConfig(this.id, this.type, this.dirs, {this.jumpDirs = const []});
}

final Map<String, PieceConfig> pieceConfigs = {
  'PR': const PieceConfig('PR', PieceShape.point, [Dir.w, Dir.se]),
  'PL': const PieceConfig('PL', PieceShape.point, [Dir.e, Dir.sw]),
  'PX': const PieceConfig('PX', PieceShape.point, [Dir.nw, Dir.ne, Dir.sw, Dir.se]),
  'DP': const PieceConfig('DP', PieceShape.diamond, [Dir.n, Dir.w, Dir.e]),
  'DT': const PieceConfig('DT', PieceShape.diamond, [Dir.n, Dir.nw, Dir.ne, Dir.s]),
  'DN': const PieceConfig('DN', PieceShape.diamond, [Dir.n, Dir.s, Dir.w, Dir.e], jumpDirs: [Dir.w, Dir.e]),
  'C':  const PieceConfig('C', PieceShape.circle, [Dir.n, Dir.sw, Dir.se]),
};

class Piece {
  final String uid;
  final String id;
  final Team team;
  int rotation; // 0, 90, 180, 270
  int immobilizedTurn;

  Piece({required this.uid, required this.id, required this.team, this.rotation = 0, this.immobilizedTurn = 0});

  PieceConfig get config => pieceConfigs[id]!;
  
  Piece copy() => Piece(uid: uid, id: id, team: team, rotation: rotation, immobilizedTurn: immobilizedTurn);
}

class MoveNode {
  final int r, c;
  MoveNode(this.r, this.c);
  @override
  bool operator ==(Object other) => identical(this, other) || other is MoveNode && r == other.r && c == other.c;
  @override
  int get hashCode => r.hashCode ^ c.hashCode;
}

class GameSnapshot {
  final List<List<Piece?>> board;
  final int pScore, oScore, turnCount;
  final Team currentTurn;
  final List<String> notation;
  GameSnapshot(this.board, this.pScore, this.oScore, this.turnCount, this.currentTurn, this.notation);
}

class BotConfig {
  int depth;
  int time;
  BotConfig({this.depth = 3, this.time = 1000});
}

// ==========================================
// GAME ENGINE & AI LOGIC
// ==========================================

class GameEngine {
  static final Map<Dir, MoveNode> _dirVecs = {
    Dir.n: MoveNode(-1, 0), Dir.s: MoveNode(1, 0),
    Dir.e: MoveNode(0, 1), Dir.w: MoveNode(0, -1),
    Dir.ne: MoveNode(-1, 1), Dir.nw: MoveNode(-1, -1),
    Dir.se: MoveNode(1, 1), Dir.sw: MoveNode(1, -1),
  };

  static List<MoveNode> getRotatedVectors(Team team, int rotation, List<Dir> baseDirs, List<Dir> jumpDirs) {
    List<MoveNode> moves = [];
    int shifts = (rotation ~/ 90) % 4;
    if (team == Team.orange) shifts = (shifts + 2) % 4; // Orange faces down

    final orderedDirs = [Dir.n, Dir.ne, Dir.e, Dir.se, Dir.s, Dir.sw, Dir.w, Dir.nw];
    
    for (var dir in baseDirs) {
      int idx = orderedDirs.indexOf(dir);
      Dir newDir = orderedDirs[(idx + shifts * 2) % 8];
      moves.add(_dirVecs[newDir]!);
    }
    for (var dir in jumpDirs) {
      int idx = orderedDirs.indexOf(dir);
      Dir newDir = orderedDirs[(idx + shifts * 2) % 8];
      MoveNode vec = _dirVecs[newDir]!;
      moves.add(MoveNode(vec.r * 2, vec.c * 2));
    }
    
    // Hardcoded DP special jump (2 steps forward)
    if (baseDirs.contains(Dir.n) && jumpDirs.isEmpty && baseDirs.contains(Dir.w) && baseDirs.contains(Dir.e)) {
        Dir fwd = orderedDirs[(0 + shifts * 2) % 8];
        MoveNode v = _dirVecs[fwd]!;
        moves.add(MoveNode(v.r * 2, v.c * 2));
    }
    return moves;
  }

  static bool inBounds(int r, int c) => r >= 0 && r < configRows && c >= 0 && c < configCols;

  static List<MoveNode> getImmediateMoves(int r, int c, Piece p, [int? customRot]) {
    int rot = customRot ?? p.rotation;
    List<MoveNode> vecs = getRotatedVectors(p.team, rot, p.config.dirs, p.config.jumpDirs);
    List<MoveNode> result = [];
    for (var v in vecs) {
      int nr = r + v.r, nc = c + v.c;
      if (inBounds(nr, nc)) result.add(MoveNode(nr, nc));
    }
    return result;
  }

  // BFS Pathfinding
  static List<MoveNode>? findPath(List<List<Piece?>> board, int sr, int sc, int dr, int dc, [int? customRot]) {
    Piece startPiece = board[sr][sc]!;
    Queue<List<MoveNode>> q = Queue()..add([MoveNode(sr, sc)]);
    Set<MoveNode> visited = {MoveNode(sr, sc)};

    while (q.isNotEmpty) {
      var path = q.removeFirst();
      var current = path.last;
      Piece? p = board[current.r][current.c];
      if (p == null) continue;

      bool isStart = current.r == sr && current.c == sc;
      var moves = getImmediateMoves(current.r, current.c, p, isStart ? customRot : null);

      for (var m in moves) {
        if (m.r == dr && m.c == dc) return [...path, m];
        Piece? target = board[m.r][m.c];
        if (target != null && target.team == startPiece.team && !visited.contains(m)) {
          visited.add(m);
          q.add([...path, m]);
        }
      }
    }
    return [MoveNode(sr, sc), MoveNode(dr, dc)]; // Fallback
  }

  // Generate All Moves for AI
  static List<Map<String, dynamic>> generateMovesForAI(List<List<Piece?>> board, Team team, int turnCount) {
    List<Map<String, dynamic>> moves = [];
    for (int r = 0; r < configRows; r++) {
      for (int c = 0; c < configCols; c++) {
        Piece? p = board[r][c];
        if (p == null || p.team != team || (p.immobilizedTurn > turnCount)) continue;

        List<int> rotations = p.config.type == PieceShape.diamond ? [0, 90, 180, 270] : [p.rotation];
        
        for (int rot in rotations) {
          Queue<MoveNode> q = Queue()..add(MoveNode(r, c));
          Set<MoveNode> visited = {MoveNode(r, c)};
          
          while (q.isNotEmpty) {
            var curr = q.removeFirst();
            Piece? currP = board[curr.r][curr.c];
            if (currP == null) continue;
            
            int effRot = (curr.r == r && curr.c == c) ? rot : currP.rotation;
            var neighbors = getImmediateMoves(curr.r, curr.c, currP, effRot);
            
            for (var n in neighbors) {
              Piece? targetP = board[n.r][n.c];
              if (targetP != null) {
                if (targetP.team != team) {
                  moves.add({'from': MoveNode(r, c), 'to': n, 'swap': true, 'rot': rot, 'val': 1000});
                } else {
                  if (!visited.contains(n)) {
                    visited.add(n);
                    q.add(n);
                  }
                }
              } else {
                if (!visited.contains(n) && !(curr.r == r && curr.c == c)) {
                  moves.add({'from': MoveNode(r, c), 'to': n, 'swap': false, 'rot': rot, 'val': 0});
                }
              }
            }
          }
        }
      }
    }
    // Basic sorting heuristic for Alpha-Beta efficiency
    for (var m in moves) {
      int destR = m['to'].r;
      m['val'] += (team == Team.purple) ? (7 - destR) : destR;
    }
    moves.sort((a, b) => b['val'].compareTo(a['val']));
    return moves;
  }

  static double evaluate(List<List<Piece?>> board, Team team, int pScore, int oScore, int turnCount) {
    bool isPurple = team == Team.purple;
    double score = 0;
    int myScore = isPurple ? pScore : oScore;
    int oppScore = isPurple ? oScore : pScore;
    
    if (myScore >= winScore) return baseWeights['WIN']!.toDouble();
    if (oppScore >= winScore) return -baseWeights['WIN']!.toDouble();
    
    score += (myScore - oppScore) * baseWeights['POINT']!;

    for (int r = 0; r < configRows; r++) {
      for (int c = 0; c < configCols; c++) {
        Piece? p = board[r][c];
        if (p == null) continue;
        
        bool isMe = p.team == team;
        int val = p.config.type == PieceShape.point ? (isPurple? 110: 100) : 
                  (p.config.type == PieceShape.diamond ? (isPurple? 350: 370) : 600);
        
        double posVal = 0;
        if (p.config.type == PieceShape.point) {
          int steps = p.team == Team.purple ? (6 - r) : (r - 1);
          posVal += (steps * steps * baseWeights['ADVANCEMENT']!);
          if (!isMe && ((p.team == Team.purple && r == 1) || (p.team == Team.orange && r == 6))) {
            score -= 5000;
          }
        }
        if (c >= 2 && c <= 4) posVal += (isPurple ? 40 : 30);
        if (p.immobilizedTurn > turnCount) {
          posVal += isMe ? baseWeights['IMMOBILIZED_SELF']! : baseWeights['IMMOBILIZE_ENEMY']!;
        }
        
        if (isMe) score += (val + posVal);
        else score -= (val + posVal);
      }
    }
    return score;
  }

  static Map<String, dynamic> applySimMove(List<List<Piece?>> board, Map<String, dynamic> move, int turnCount, int pScore, int oScore) {
    MoveNode f = move['from'];
    MoveNode t = move['to'];
    
    Piece movingP = board[f.r][f.c]!.copy();
    movingP.rotation = move['rot'];
    Piece? targetP = board[t.r][t.c]?.copy();

    int sAdd = 0;
    bool remMoving = false;
    bool remTarget = false;

    if (move['swap'] && movingP.id == 'C' && targetP?.id == 'C') {
      remTarget = true;
      sAdd += 2;
    }

    int promoRow = movingP.team == Team.purple ? 0 : 7;
    if (movingP.config.type == PieceShape.point && t.r == promoRow) {
      remMoving = true;
      if (movingP.id != 'PX') sAdd = sAdd > 0 ? sAdd : 1;
    }

    if (movingP.team == Team.purple) pScore += sAdd; else oScore += sAdd;

    board[f.r][f.c] = null;
    if (move['swap'] && !remTarget) {
      targetP!.immobilizedTurn = turnCount + 2;
      board[f.r][f.c] = targetP;
    }
    board[t.r][t.c] = remMoving ? null : movingP;

    return {'board': board, 'pScore': pScore, 'oScore': oScore};
  }

  static double minimax(List<List<Piece?>> board, int depth, double alpha, double beta, bool isMax, int turnCount, int pScore, int oScore, int startTime, int maxTime, Team initialTeam) {
    Team currentTeam = isMax ? initialTeam : (initialTeam == Team.purple ? Team.orange : Team.purple);
    
    if (depth == 0 || pScore >= winScore || oScore >= winScore || (DateTime.now().millisecondsSinceEpoch - startTime > maxTime)) {
      return evaluate(board, initialTeam, pScore, oScore, turnCount);
    }

    var moves = generateMovesForAI(board, currentTeam, turnCount);
    if (moves.isEmpty) return evaluate(board, initialTeam, pScore, oScore, turnCount);

    if (isMax) {
      double maxE = double.negativeInfinity;
      for (var m in moves) {
        var nb = board.map((r) => r.map((p) => p?.copy()).toList()).toList();
        var res = applySimMove(nb, m, turnCount, pScore, oScore);
        double ev = minimax(res['board'], depth - 1, alpha, beta, false, turnCount + 1, res['pScore'], res['oScore'], startTime, maxTime, initialTeam);
        maxE = max(maxE, ev);
        alpha = max(alpha, ev);
        if (beta <= alpha) break;
      }
      return maxE;
    } else {
      double minE = double.infinity;
      for (var m in moves) {
        var nb = board.map((r) => r.map((p) => p?.copy()).toList()).toList();
        var res = applySimMove(nb, m, turnCount, pScore, oScore);
        double ev = minimax(res['board'], depth - 1, alpha, beta, true, turnCount + 1, res['pScore'], res['oScore'], startTime, maxTime, initialTeam);
        minE = min(minE, ev);
        beta = min(beta, ev);
        if (beta <= alpha) break;
      }
      return minE;
    }
  }
}

// ==========================================
// GAME STATE MANAGEMENT
// ==========================================

class GameState extends ChangeNotifier {
  List<List<Piece?>> board = List.generate(8, (_) => List.filled(7, null));
  int pScore = 0, oScore = 0, turnCount = 1;
  Team currentTurn = Team.purple;
  bool isGameOver = false;
  String? winnerMsg;
  
  String gameMode = 'bot'; // '2p', 'bot', 'botvbot', 'explorer'
  Team botTeam = Team.orange;
  
  MoveNode? selectedCell;
  Set<MoveNode> availableCells = {};
  Set<MoveNode> swapCells = {};
  MoveNode? invalidCell; // For wobble animation

  bool isAnimating = false;
  bool isRotating = false;
  int rotationVis = 0;
  int rotationsThisTurn = 0;
  String? rotatedPieceId;

  List<GameSnapshot> history = [];
  List<String> notation = [];
  
  // Explorer
  List<String> explorerMoves = [];
  int explorerIndex = 0;

  BotConfig pBot = BotConfig();
  BotConfig oBot = BotConfig();

  int _uidCounter = 0;

  GameState() { resetGame(); }

  void resetGame() {
    board = List.generate(8, (_) => List.filled(7, null));
    pScore = oScore = 0;
    turnCount = 1;
    currentTurn = Team.purple;
    isGameOver = false;
    winnerMsg = null;
    history.clear();
    if (gameMode != 'explorer' || explorerIndex == 0) notation.clear();
    clearSelection();
    _setupBoard();
    notifyListeners();
    _checkBotTurn();
  }

  void _setupBoard() {
    final pSetup = [
      ['PR', 6, 0], ['PL', 6, 1], ['PR', 6, 2], ['PX', 6, 3], ['PL', 6, 4], ['PR', 6, 5], ['PL', 6, 6],
      ['DP', 7, 0], ['DT', 7, 1], ['DN', 7, 2], ['C',  7, 3], ['DN', 7, 4], ['DT', 7, 5], ['DP', 7, 6]
    ];
    final oSetup = [
      ['PL', 1, 0], ['PR', 1, 1], ['PL', 1, 2], ['PX', 1, 3], ['PR', 1, 4], ['PL', 1, 5], ['PR', 1, 6],
      ['DP', 0, 0], ['DT', 0, 1], ['DN', 0, 2], ['C',  0, 3], ['DN', 0, 4], ['DT', 0, 5], ['DP', 0, 6]
    ];
    for (var s in pSetup) board[s[1] as int][s[2] as int] = Piece(uid: '${_uidCounter++}', id: s[0] as String, team: Team.purple);
    for (var s in oSetup) board[s[1] as int][s[2] as int] = Piece(uid: '${_uidCounter++}', id: s[0] as String, team: Team.orange, rotation: 180);
  }

  void _saveSnapshot() {
    var bCopy = board.map((r) => r.map((p) => p?.copy()).toList()).toList();
    history.add(GameSnapshot(bCopy, pScore, oScore, turnCount, currentTurn, List.from(notation)));
    if (history.length > 50) history.removeAt(0);
  }

  void handleUndo() {
    if (isAnimating || isGameOver || history.isEmpty) return;
    GameSnapshot snap;
    if (gameMode == 'bot' && history.length >= 2) {
      history.removeLast();
      snap = history.removeLast();
    } else {
      snap = history.removeLast();
    }
    board = snap.board;
    pScore = snap.pScore; oScore = snap.oScore;
    turnCount = snap.turnCount; currentTurn = snap.currentTurn;
    notation = snap.notation;
    clearSelection();
    notifyListeners();
  }

  void clearSelection() {
    selectedCell = null;
    availableCells.clear();
    swapCells.clear();
    isRotating = false;
  }

  void triggerInvalid(int r, int c) {
    invalidCell = MoveNode(r, c);
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (invalidCell?.r == r && invalidCell?.c == c) {
        invalidCell = null;
        notifyListeners();
      }
    });
  }

  void cellClicked(int r, int c) async {
    if (isAnimating || isGameOver || (gameMode == 'bot' && currentTurn == botTeam) || gameMode == 'botvbot' || gameMode == 'explorer') return;

    if (isRotating) {
      if (selectedCell != null && selectedCell!.r == r && selectedCell!.c == c) {
        rotationVis = (rotationVis + 90) % 360;
        notifyListeners();
      }
      return;
    }

    MoveNode clicked = MoveNode(r, c);

    if (selectedCell != null && (availableCells.contains(clicked) || swapCells.contains(clicked))) {
      var path = GameEngine.findPath(board, selectedCell!.r, selectedCell!.c, r, c);
      await executeMove(selectedCell!, clicked, path ?? [selectedCell!, clicked], swapCells.contains(clicked), board[selectedCell!.r][selectedCell!.c]!.rotation);
      return;
    }

    Piece? p = board[r][c];
    if (p != null) {
      if (p.team != currentTurn || (p.immobilizedTurn > turnCount)) { triggerInvalid(r, c); return; }
      
      if (selectedCell == clicked) { clearSelection(); notifyListeners(); }
      else {
        clearSelection();
        selectedCell = clicked;
        _calcHighlights(r, c, p);
        notifyListeners();
      }
    } else {
      clearSelection();
      triggerInvalid(r, c);
    }
  }

  void _calcHighlights(int r, int c, Piece p) {
    // Replicates progressive layer highlighting instantly for robust Flutter UI state
    Queue<MoveNode> q = Queue()..add(MoveNode(r, c));
    Set<MoveNode> visited = {MoveNode(r, c)};
    while (q.isNotEmpty) {
      var curr = q.removeFirst();
      Piece? currP = board[curr.r][curr.c];
      if (currP == null) continue;
      
      int effRot = (curr.r == r && curr.c == c) ? p.rotation : currP.rotation;
      var neighbors = GameEngine.getImmediateMoves(curr.r, curr.c, currP, effRot);
      
      for (var n in neighbors) {
        Piece? target = board[n.r][n.c];
        if (target != null) {
          swapCells.add(n);
          if (target.team == p.team && !visited.contains(n)) { visited.add(n); q.add(n); }
        } else if (!(curr.r == r && curr.c == c)) {
          availableCells.add(n);
          visited.add(n);
        }
      }
    }
  }

  // Called by UI Controller
  Future<void> executeMove(MoveNode from, MoveNode to, List<MoveNode> path, bool isSwap, int preRot) async {
    if (isAnimating) return;
    _saveSnapshot();
    
    Piece movingP = board[from.r][from.c]!;
    Piece? targetP = isSwap ? board[to.r][to.c] : null;

    // Notation
    if (gameMode != 'explorer') {
      String sc = String.fromCharCode(97 + from.c) + (8 - from.r).toString();
      String ec = String.fromCharCode(97 + to.c) + (8 - to.r).toString();
      String rotStr = (preRot != movingP.rotation) ? 'R$preRot' : '';
      String act = isSwap ? 'x' : '-';
      notation.add('${movingP.id}$sc$rotStr$act$ec');
    }

    movingP.rotation = preRot;
    isAnimating = true;
    clearSelection();
    notifyListeners();

    // The View will listen to `isAnimating` and `path` and do the juicy animation.
    // For architecture limits, we simulate the time delay here for logic sync.
    await Future.delayed(Duration(milliseconds: 240 * (path.length - 1 > 0 ? path.length - 1 : 1)));

    int sAdd = 0;
    bool remMoving = false, remTarget = false;

    if (isSwap && movingP.id == 'C' && targetP?.id == 'C') { remTarget = true; sAdd += 2; }
    int pRow = movingP.team == Team.purple ? 0 : 7;
    if (movingP.config.type == PieceShape.point && to.r == pRow) {
      remMoving = true;
      if (movingP.id != 'PX') sAdd = sAdd > 0 ? sAdd : 1;
    }

    board[from.r][from.c] = null;
    if (isSwap && !remTarget) {
      targetP!.immobilizedTurn = turnCount + 2;
      board[from.r][from.c] = targetP;
    }
    board[to.r][to.c] = remMoving ? null : movingP;

    if (sAdd > 0) {
      if (currentTurn == Team.purple) pScore += sAdd; else oScore += sAdd;
      if (pScore >= winScore) { isGameOver = true; winnerMsg = 'Purple'; }
      if (oScore >= winScore) { isGameOver = true; winnerMsg = 'Orange'; }
    }

    isAnimating = false;
    if (!isGameOver) _switchTurn();
    notifyListeners();
  }

  void _switchTurn() {
    turnCount++;
    currentTurn = currentTurn == Team.purple ? Team.orange : Team.purple;
    rotationsThisTurn = 0;
    rotatedPieceId = null;
    
    // Check Immobilized
    for (int r=0; r<8; r++) {
      for (int c=0; c<7; c++) {
        if (board[r][c]?.team == currentTurn && board[r][c]!.immobilizedTurn <= turnCount) {
          board[r][c]!.immobilizedTurn = 0;
        }
      }
    }
    _checkBotTurn();
  }

  void _checkBotTurn() async {
    if (isGameOver) return;
    if (gameMode == 'botvbot' || (gameMode == 'bot' && currentTurn == botTeam)) {
      await Future.delayed(const Duration(milliseconds: 500));
      BotConfig c = currentTurn == Team.purple ? pBot : oBot;
      var bData = board.map((r) => r.map((p) => p?.copy()).toList()).toList();
      var moves = GameEngine.generateMovesForAI(bData, currentTurn, turnCount);
      
      if (moves.isEmpty) { _switchTurn(); return; }
      
      var bestM = moves[0];
      double bestV = double.negativeInfinity;
      double alpha = double.negativeInfinity;
      int st = DateTime.now().millisecondsSinceEpoch;

      for (var m in moves) {
        if (DateTime.now().millisecondsSinceEpoch - st > c.time) break;
        var nb = bData.map((r) => r.map((p) => p?.copy()).toList()).toList();
        var res = GameEngine.applySimMove(nb, m, turnCount, pScore, oScore);
        double ev = GameEngine.minimax(res['board'], c.depth - 1, alpha, double.infinity, false, turnCount+1, res['pScore'], res['oScore'], st, c.time, currentTurn);
        if (ev > bestV) { bestV = ev; bestM = m; }
        alpha = max(alpha, bestV);
      }
      
      MoveNode f = bestM['from']; MoveNode t = bestM['to'];
      var path = GameEngine.findPath(board, f.r, f.c, t.r, t.c, bestM['rot']);
      await executeMove(f, t, path ?? [f, t], bestM['swap'], bestM['rot']);
    }
  }

  // Rotation Modals
  void toggleRotationMode() {
    if (selectedCell == null) return;
    Piece p = board[selectedCell!.r][selectedCell!.c]!;
    if (rotationsThisTurn >= 2 || p.uid == rotatedPieceId) return;
    isRotating = true;
    rotationVis = p.rotation;
    notifyListeners();
  }

  void confirmRotation() {
    Piece p = board[selectedCell!.r][selectedCell!.c]!;
    if (p.rotation != rotationVis % 360) {
      p.rotation = rotationVis % 360;
      rotationsThisTurn++;
      rotatedPieceId = p.uid;
    }
    isRotating = false;
    _calcHighlights(selectedCell!.r, selectedCell!.c, p);
    notifyListeners();
  }

  void cancelRotation() { isRotating = false; notifyListeners(); }
}
// ==========================================
// MAIN APP & UI LAYOUT
// ==========================================

class GyroadApp extends StatelessWidget {
  const GyroadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GYROAD',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Georgia',
      ),
      home: const GameScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with TickerProviderStateMixin {
  late GameState _state;
  final TextEditingController _explorerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _state = GameState();
  }

  @override
  void dispose() {
    _state.dispose();
    _explorerController.dispose();
    super.dispose();
  }

  void _showSettingsModal() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return StatefulBuilder(builder: (context, setStateModal) {
          return Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                constraints: const BoxConstraints(maxWidth: 500),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0C).withOpacity(0.95),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border, width: 2),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Game Mode', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
                      const SizedBox(height: 15),
                      _buildModeBtn('2-Player (Local)', '2p', setStateModal),
                      const SizedBox(height: 10),
                      _buildModeBtn('1-Player (vs Bot)', 'bot', setStateModal),
                      const SizedBox(height: 10),
                      _buildModeBtn('Bot vs Bot', 'botvbot', setStateModal),
                      const SizedBox(height: 20),
                      const Text('AI Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.purpleEnergy)),
                      const SizedBox(height: 10),
                      _buildSliderRow('Purple Depth', _state.pBot.depth.toDouble(), 1, 5, (v) { _state.pBot.depth = v.toInt(); setStateModal((){}); }),
                      _buildSliderRow('Purple Time (ms)', _state.pBot.time.toDouble(), 100, 3000, (v) { _state.pBot.time = v.toInt(); setStateModal((){}); }, divisions: 29),
                      const SizedBox(height: 15),
                      const Text('Orange Bot', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.orangeEnergy)),
                      _buildSliderRow('Orange Depth', _state.oBot.depth.toDouble(), 1, 5, (v) { _state.oBot.depth = v.toInt(); setStateModal((){}); }),
                      _buildSliderRow('Orange Time (ms)', _state.oBot.time.toDouble(), 100, 3000, (v) { _state.oBot.time = v.toInt(); setStateModal((){}); }, divisions: 29),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800], minimumSize: const Size(double.infinity, 50)),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 18, fontStyle: FontStyle.italic)),
                      )
                    ],
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  void _showExplorerModal() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Explorer',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              constraints: const BoxConstraints(maxWidth: 500),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0C).withOpacity(0.95),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Game Explorer', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
                  const SizedBox(height: 10),
                  const Text('Paste game notation below to explore the match step-by-step.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _explorerController,
                    maxLines: 6,
                    style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Colors.black54,
                      border: OutlineInputBorder(),
                      hintText: "1. PRa2-a3 PLg7-g6\n2. DNe2R90xe3 ...",
                    ),
                  ),
                  const SizedBox(height: 15),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.cellHover, minimumSize: const Size(double.infinity, 50)),
                    onPressed: () {
                      final RegExp exp = RegExp(r'([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])');
                      final matches = exp.allMatches(_explorerController.text);
                      List<String> moves = matches.map((m) => m.group(0)!).toList();
                      if (moves.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid moves found.')));
                        return;
                      }
                      _state.explorerMoves = moves;
                      _state.gameMode = 'explorer';
                      _state.explorerIndex = 0;
                      _state.resetGame();
                      Navigator.pop(context);
                    },
                    child: const Text('Load Game', style: TextStyle(color: Colors.white, fontSize: 18, fontStyle: FontStyle.italic)),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800], minimumSize: const Size(double.infinity, 50)),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white, fontSize: 18, fontStyle: FontStyle.italic)),
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildModeBtn(String text, String mode, StateSetter setStateModal) {
    bool isActive = _state.gameMode == mode;
    return GestureDetector(
      onTap: () {
        _state.gameMode = mode;
        if (mode == 'bot') _state.botTeam = Team.orange;
        _state.resetGame();
        Navigator.pop(context);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isActive ? [AppColors.purpleEnergy, AppColors.purpleEnergy] : [const Color(0xFF6A5A87), const Color(0xFF3B314A)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          border: Border.all(color: isActive ? Colors.white : AppColors.border, width: 2),
          boxShadow: isActive ? [const BoxShadow(color: AppColors.purpleEnergy, blurRadius: 15)] : [const BoxShadow(color: Colors.black54, blurRadius: 5, offset: Offset(0, 2))],
        ),
        alignment: Alignment.center,
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
      ),
    );
  }

  Widget _buildSliderRow(String label, double val, double min, double max, ValueChanged<double> onChanged, {int? divisions}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            Text(val.toInt().toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        Slider(
          value: val, min: min, max: max, divisions: divisions ?? (max - min).toInt(),
          activeColor: AppColors.purpleEnergy,
          onChanged: onChanged,
        ),
      ],
    );
  }

  void _handleExplorerNext() async {
    if (_state.isAnimating || _state.explorerIndex >= _state.explorerMoves.length) return;
    String moveStr = _state.explorerMoves[_state.explorerIndex];
    final RegExp exp = RegExp(r'^([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])$');
    var m = exp.firstMatch(moveStr);
    if (m == null) return;
    
    int sr = 8 - int.parse(m.group(2)![1]);
    int sc = m.group(2)!.codeUnitAt(0) - 97;
    int dr = 8 - int.parse(m.group(5)![1]);
    int dc = m.group(5)!.codeUnitAt(0) - 97;
    int? rot = m.group(3) != null ? int.parse(m.group(3)!) : null;
    bool isSwap = m.group(4) == 'x';

    var path = GameEngine.findPath(_state.board, sr, sc, dr, dc, rot);
    _state.notation.add(moveStr);
    await _state.executeMove(MoveNode(sr, sc), MoveNode(dr, dc), path ?? [MoveNode(sr, sc), MoveNode(dr, dc)], isSwap, rot ?? _state.board[sr][sc]!.rotation);
    _state.explorerIndex++;
  }

  void _handleExplorerPrev() {
    if (_state.isAnimating || _state.explorerIndex <= 0) return;
    _state.handleUndo();
    _state.explorerIndex--;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _state,
      builder: (context, _) {
        return Scaffold(
          body: Stack(
            children: [
              // Top Scores
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildScoreBars(Team.purple, _state.pScore),
                        _buildScoreBars(Team.orange, _state.oScore),
                      ],
                    ),
                  ),
                ),
              ),

              // Game Board Center
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.boardBg,
                        border: Border.all(color: _state.currentTurn == Team.purple ? AppColors.purpleEnergy : AppColors.orangeEnergy, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 20)],
                      ),
                      padding: const EdgeInsets.all(4),
                      child: BoardWidget(state: _state),
                    ),
                    const SizedBox(height: 10),
                    // Notation Ticker
                    Container(
                      width: MediaQuery.of(context).size.width * 0.9,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: Text(
                                _state.notation.isEmpty ? 'Game Start' : _state.notation.asMap().entries.map((e) => e.key % 2 == 0 ? '${(e.key~/2)+1}. ${e.value}' : e.value).join(' '),
                                style: const TextStyle(fontFamily: 'monospace', color: Colors.white70, fontSize: 14),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (_state.gameMode != 'explorer') ...[
                            _buildActionBtn('Copy', () => Clipboard.setData(ClipboardData(text: _state.notation.join(' ')))),
                            const SizedBox(width: 5),
                            _buildActionBtn('Explorer', _showExplorerModal),
                          ] else ...[
                            _buildActionBtn('<', _handleExplorerPrev),
                            const SizedBox(width: 5),
                            _buildActionBtn('>', _handleExplorerNext),
                            const SizedBox(width: 5),
                            _buildActionBtn('Exit', () { _state.gameMode = 'bot'; _state.resetGame(); }),
                          ]
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Controls (Rotation & Undo & Settings)
              if (_state.isRotating)
                Positioned(
                  left: 20, top: MediaQuery.of(context).size.height / 2,
                  child: Column(
                    children: [
                      FloatingActionButton(heroTag: 'rotC', backgroundColor: AppColors.purpleEnergy, mini: true, onPressed: _state.confirmRotation, child: const Icon(Icons.check, color: Colors.white)),
                      const SizedBox(height: 10),
                      FloatingActionButton(heroTag: 'rotX', backgroundColor: Colors.grey[800], mini: true, onPressed: _state.cancelRotation, child: const Icon(Icons.close, color: Colors.white)),
                    ],
                  ),
                ),

              if (!_state.isRotating && _state.selectedCell != null && _state.board[_state.selectedCell!.r][_state.selectedCell!.c]?.config.type == PieceShape.diamond && _state.rotationsThisTurn < 2 && _state.board[_state.selectedCell!.r][_state.selectedCell!.c]?.uid != _state.rotatedPieceId)
                Positioned(
                  left: 20, top: MediaQuery.of(context).size.height / 2,
                  child: FloatingActionButton(
                    heroTag: 'rotBtn',
                    backgroundColor: AppColors.cellHover,
                    onPressed: _state.toggleRotationMode,
                    child: const Icon(Icons.rotate_right, color: Colors.white),
                  ),
                ),

              if (_state.history.isNotEmpty && _state.gameMode != 'explorer' && _state.gameMode != 'botvbot')
                Positioned(
                  right: 20, bottom: 20,
                  child: FloatingActionButton(
                    heroTag: 'undoBtn',
                    backgroundColor: AppColors.cellHover,
                    onPressed: _state.handleUndo,
                    child: const Icon(Icons.undo, color: Colors.white),
                  ),
                ),

              Positioned(
                left: MediaQuery.of(context).size.width / 2 - 28, bottom: 20,
                child: FloatingActionButton(
                  heroTag: 'settingsBtn',
                  backgroundColor: AppColors.cellHover,
                  onPressed: _showSettingsModal,
                  child: const Icon(Icons.settings, color: Colors.white),
                ),
              ),

              // Win Overlay
              if (_state.isGameOver)
                Container(
                  color: Colors.black.withOpacity(0.7),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_state.winnerMsg} Wins!', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white, shadows: [BoxShadow(color: _state.winnerMsg == 'Purple' ? AppColors.purpleEnergy : AppColors.orangeEnergy, blurRadius: 20)])),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.cellHover, padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15)),
                        onPressed: _state.resetGame,
                        child: const Text('Play Again', style: TextStyle(fontSize: 20, color: Colors.white, fontStyle: FontStyle.italic)),
                      )
                    ],
                  ),
                ),
            ],
          ),
        );
      }
    );
  }

  Widget _buildScoreBars(Team team, int score) {
    Color c = team == Team.purple ? AppColors.purpleEnergy : AppColors.orangeEnergy;
    return Row(
      children: List.generate(winScore, (i) {
        bool filled = i < score;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 25, height: 12,
          decoration: BoxDecoration(
            color: filled ? c : Colors.transparent,
            border: Border.all(color: c, width: 2),
            boxShadow: filled ? [BoxShadow(color: c.withOpacity(0.5), blurRadius: 5)] : null,
          ),
        );
      }),
    );
  }

  Widget _buildActionBtn(String text, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF6A5A87), Color(0xFF3B314A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
      ),
    );
  }
}

// ==========================================
// VISUAL ENGINE: BOARD & CUSTOM PAINT
// ==========================================

class BoardWidget extends StatelessWidget {
  final GameState state;
  const BoardWidget({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    double boardWidth = MediaQuery.of(context).size.width * 0.95;
    double maxH = MediaQuery.of(context).size.height - 180;
    double cellW = boardWidth / configCols;
    double cellH = cellW; // Enforce square cells
    
    if (cellH * configRows > maxH) {
      cellH = maxH / configRows;
      cellW = cellH;
    }

    return SizedBox(
      width: cellW * configCols,
      height: cellH * configRows,
      child: Stack(
        children: [
          // Background Cells
          GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: configCols,
              childAspectRatio: 1.0,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: configRows * configCols,
            itemBuilder: (context, index) {
              int r = index ~/ configCols;
              int c = index % configCols;
              MoveNode node = MoveNode(r, c);
              
              bool isSelected = state.selectedCell == node;
              bool isAvail = state.availableCells.contains(node);
              bool isSwap = state.swapCells.contains(node);
              bool isInvalid = state.invalidCell == node;

              Color bgColor = AppColors.cell;
              List<BoxShadow> shadows = [];
              
              if (isSelected) {
                bgColor = const Color(0xFF9370DB);
                shadows = [const BoxShadow(color: Color(0xFF9370DB), blurRadius: 20, spreadRadius: 5)];
              } else if (isAvail) {
                bgColor = const Color(0xFFD8B4FE);
                shadows = [const BoxShadow(color: Color(0xFFC79BFF), blurRadius: 15)];
              } else if (isSwap) {
                bgColor = const Color(0xFFFFB3C1);
                shadows = [const BoxShadow(color: Color(0xFFFF7A90), blurRadius: 15)];
              } else if (isInvalid) {
                bgColor = Colors.red[900]!;
              }

              return GestureDetector(
                onTap: () => state.cellClicked(r, c),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: isInvalid ? const EdgeInsets.only(left: 4, right: 0) : EdgeInsets.zero, // Cheap wobble sim
                  decoration: BoxDecoration(color: bgColor, boxShadow: shadows),
                ),
              );
            },
          ),
          // Pieces Layer (AnimatedPositioned for juicy path sliding)
          ..._buildPieces(cellW, cellH),
        ],
      ),
    );
  }

  List<Widget> _buildPieces(double cw, double ch) {
    List<Widget> pWidgets = [];
    double gap = 4.0;
    double effW = cw - (gap * (configCols - 1) / configCols);
    double effH = ch - (gap * (configRows - 1) / configRows);

    for (int r = 0; r < configRows; r++) {
      for (int c = 0; c < configCols; c++) {
        Piece? p = state.board[r][c];
        if (p == null) continue;

        bool isSelected = state.selectedCell?.r == r && state.selectedCell?.c == c;
        int displayRot = (isSelected && state.isRotating) ? state.rotationVis : p.rotation;

        pWidgets.add(
          AnimatedPositioned(
            key: ValueKey(p.uid),
            duration: state.isAnimating ? const Duration(milliseconds: 240) : const Duration(milliseconds: 100),
            curve: Curves.easeInOutSine,
            left: c * cw,
            top: r * ch,
            width: effW,
            height: effH,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: p.immobilizedTurn > state.turnCount ? 0.4 : 1.0,
                child: AnimatedScale(
                  scale: isSelected ? 1.05 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: CustomPaint(
                    painter: PiecePainter(
                      piece: p,
                      rotation: displayRot.toDouble(),
                      isSelected: isSelected,
                    ),
                  ),
                ),
              ),
            ),
          )
        );
      }
    }
    return pWidgets;
  }
}

class PiecePainter extends CustomPainter {
  final Piece piece;
  final double rotation;
  final bool isSelected;

  PiecePainter({required this.piece, required this.rotation, this.isSelected = false});

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final Team team = piece.team;
    
    // Convert logic rotation + team base rotation to radians
    double baseRot = team == Team.orange ? pi : 0;
    double logicRot = rotation * pi / 180;
    double totalRot = baseRot + logicRot;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(totalRot);
    canvas.translate(-cx, -cy);

    Color eColor = team == Team.purple ? AppColors.purpleEnergy : AppColors.orangeEnergy;
    Color eGlow = team == Team.purple ? AppColors.purpleGlow : AppColors.orangeGlow;

    // Dimensions based on CSS strict percentages
    double connectorW = size.width * 0.06;
    double connectorL = size.height * 0.42;
    double nodeSize = size.width * 0.17;
    double nodeOffset = size.width * 0.06;
    double centerSize = piece.config.type == PieceShape.diamond ? size.width * 0.25 :
                        piece.config.type == PieceShape.circle ? size.width * 0.40 : size.width * 0.20;

    final Paint metalBase = Paint()
      ..shader = const LinearGradient(
        colors: [AppColors.metalShadow, Color(0xFF2A2E37)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final Paint nodePaint = Paint()
      ..shader = RadialGradient(
        colors: isSelected ? [eGlow, eColor] : [AppColors.metalHighlight, AppColors.metalBase],
        center: const Alignment(-0.3, -0.3), radius: 0.8
      ).createShader(Rect.fromLTWH(0, 0, nodeSize, nodeSize));

    final Paint jumpNodePaint = Paint()
      ..shader = const RadialGradient(
        colors: [AppColors.metalShadow, Colors.black],
        center: Alignment.center, radius: 0.8
      ).createShader(Rect.fromLTWH(0, 0, nodeSize, nodeSize));

    final Map<Dir, Offset> dirAngles = {
      Dir.n: const Offset(0, -1), Dir.ne: const Offset(1, -1),
      Dir.e: const Offset(1, 0), Dir.se: const Offset(1, 1),
      Dir.s: const Offset(0, 1), Dir.sw: const Offset(-1, 1),
      Dir.w: const Offset(-1, 0), Dir.nw: const Offset(-1, -1),
    };

    final Map<Dir, Offset> nodePositions = {
      Dir.n: Offset(cx, nodeOffset + nodeSize/2),
      Dir.ne: Offset(size.width - nodeOffset - nodeSize/2, nodeOffset + nodeSize/2),
      Dir.e: Offset(size.width - nodeOffset - nodeSize/2, cy),
      Dir.se: Offset(size.width - nodeOffset - nodeSize/2, size.height - nodeOffset - nodeSize/2),
      Dir.s: Offset(cx, size.height - nodeOffset - nodeSize/2),
      Dir.sw: Offset(nodeOffset + nodeSize/2, size.height - nodeOffset - nodeSize/2),
      Dir.w: Offset(nodeOffset + nodeSize/2, cy),
      Dir.nw: Offset(nodeOffset + nodeSize/2, nodeOffset + nodeSize/2),
    };

    // Draw Connectors
    for (var dir in piece.config.dirs) {
      canvas.save();
      canvas.translate(cx, cy);
      double angle = atan2(dirAngles[dir]!.dy, dirAngles[dir]!.dx) + pi/2;
      canvas.rotate(angle);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(-connectorW/2, -connectorL, connectorW, connectorL), const Radius.circular(2)), metalBase);
      canvas.restore();
    }

    // Draw Nodes
    for (var dir in piece.config.dirs) {
      Offset pos = nodePositions[dir]!;
      bool isJump = piece.config.jumpDirs.contains(dir);
      bool isPower = piece.id == 'DP' && dir == Dir.n;

      Paint activePaint = isPower ? (Paint()..color = Colors.white) : (isJump ? jumpNodePaint : nodePaint);
      
      if (isSelected) {
        canvas.drawCircle(pos, nodeSize/2, Paint()..color = eColor..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      }
      canvas.drawCircle(pos, nodeSize/2, activePaint);
      canvas.drawCircle(pos, nodeSize/2, Paint()..color = isSelected ? eGlow : AppColors.metalShadow..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }

    // Draw Centerpiece
    canvas.save();
    canvas.translate(cx, cy);
    if (piece.config.type == PieceShape.diamond) canvas.rotate(pi/4);
    
    Rect centerRect = Rect.fromCenter(center: Offset.zero, width: centerSize, height: centerSize);
    Paint centerBg = Paint()
      ..shader = const LinearGradient(colors: [AppColors.metalHighlight, AppColors.metalBase], begin: Alignment.topLeft, end: Alignment.bottomRight)
      .createShader(centerRect);
    
    if (piece.config.type == PieceShape.diamond) {
      canvas.drawRect(centerRect, centerBg);
      canvas.drawRect(centerRect, Paint()..color = AppColors.metalShadow..style = PaintingStyle.stroke..strokeWidth = 1);
    } else {
      canvas.drawCircle(Offset.zero, centerSize/2, centerBg);
      canvas.drawCircle(Offset.zero, centerSize/2, Paint()..color = AppColors.metalShadow..style = PaintingStyle.stroke..strokeWidth = 1);
    }

    // Gem Inside Centerpiece
    double gemSize = centerSize * 0.6;
    Rect gemRect = Rect.fromCenter(center: Offset.zero, width: gemSize, height: gemSize);
    Paint gemPaint = Paint()
      ..shader = RadialGradient(colors: [eGlow, eColor], center: const Alignment(-0.3, -0.3), radius: 0.8)
      .createShader(gemRect);

    if (isSelected) {
      Paint glowPaint = Paint()..color = eColor..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      piece.config.type == PieceShape.diamond ? canvas.drawRect(gemRect, glowPaint) : canvas.drawCircle(Offset.zero, gemSize/2, glowPaint);
    }

    if (piece.config.type == PieceShape.diamond) {
      canvas.drawRect(gemRect, gemPaint);
    } else {
      canvas.drawCircle(Offset.zero, gemSize/2, gemPaint);
    }
    
    canvas.restore(); // Centerpiece
    canvas.restore(); // Global rotation
  }

  @override
  bool shouldRepaint(covariant PiecePainter oldDelegate) {
    return oldDelegate.rotation != rotation || oldDelegate.isSelected != isSelected;
  }
}


