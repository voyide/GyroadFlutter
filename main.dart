import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const GyroadApp());

const int ROWS = 8; const int COLS = 7; const int WIN_SCORE = 6;
const int LAYER_DELAY_MS = 80; const int STEP_DURATION_MS = 240;

const Color bgColor = Color(0xFF1A1A1A); const Color boardBg = Color(0xFF2A2235);
const Color cellColor = Color(0xFF584A73); const Color cellHoverColor = Color(0xFF6A5A87);
const Color borderColor = Color(0xFF3B314A); const Color selectedColor = Color(0xFF9370DB);
const Color availableColor = Color(0xFFD8B4FE); const Color swapColor = Color(0xFFFFB3C1);
const Color metalBaseColor = Color(0xFF9AA0B8); const Color metalHighlightColor = Color(0xFFEDEAF9);
const Color metalShadowColor = Color(0xFF454B61);

class TeamTheme { final Color color, glow; const TeamTheme(this.color, this.glow); }
const TeamTheme purpleTheme = TeamTheme(Color(0xFFA87CFF), Color(0xFFEAD8FF));
const TeamTheme orangeTheme = TeamTheme(Color(0xFFFF6B6B), Color(0xFFFFD6D6));

final Map<String, int> PURPLE_WEIGHTS = {'WIN': 1000000, 'POINT': 15000, 'CAPTURE_CIRCLE': 8000, 'PIECE_P': 110, 'PIECE_D': 350, 'PIECE_C': 600, 'ADVANCEMENT': 20, 'CENTER_CONTROL': 40, 'THREATENED': -200, 'IMMOBILIZE_ENEMY': 500, 'IMMOBILIZED_SELF': -400};
final Map<String, int> ORANGE_WEIGHTS = {'WIN': 1000000, 'POINT': 15000, 'CAPTURE_CIRCLE': 8000, 'PIECE_P': 100, 'PIECE_D': 370, 'PIECE_C': 600, 'ADVANCEMENT': 20, 'CENTER_CONTROL': 30, 'THREATENED': -250, 'IMMOBILIZE_ENEMY': 500, 'IMMOBILIZED_SELF': -400};

class PieceConfig {
  final String id, type; final List<String> directions, jumpDirections;
  const PieceConfig(this.id, this.type, this.directions, [this.jumpDirections = const []]);
}
const Map<String, PieceConfig> CONFIG_BY_ID = {
  'PR': PieceConfig('PR', 'P', ['w', 'se']), 'PL': PieceConfig('PL', 'P', ['e', 'sw']),
  'PX': PieceConfig('PX', 'P', ['nw', 'ne', 'sw', 'se']), 'DP': PieceConfig('DP', 'D', ['n', 'w', 'e']),
  'DT': PieceConfig('DT', 'D', ['n', 'nw', 'ne', 's']), 'DN': PieceConfig('DN', 'D',['n', 's', 'w', 'e'], ['w', 'e']),
  'C':  PieceConfig('C', 'C', ['n', 'sw', 'se']),
};

class PieceData {
  String id, type, team; int rotation, immobilizedTurn, uid;
  PieceData({required this.id, required this.type, required this.team, this.rotation = 0, this.immobilizedTurn = 0, required this.uid});
  PieceData clone() => PieceData(id: id, type: type, team: team, rotation: rotation, immobilizedTurn: immobilizedTurn, uid: uid);
}

class Coordinate {
  final int r, c; const Coordinate(this.r, this.c);
  @override bool operator ==(Object o) => o is Coordinate && r == o.r && c == o.c;
  @override int get hashCode => Object.hash(r, c);
}

class MoveAction {
  final Coordinate from, to; final bool isSwap; final int preMoveRotation; int scoreVal;
  MoveAction(this.from, this.to, this.isSwap, this.preMoveRotation, [this.scoreVal = 0]);
}

class GameSnapshot {
  final List<List<PieceData?>> board; final int pScore, oScore, turnCount;
  final String currentTurn; final List<String> notation;
  GameSnapshot(this.board, this.pScore, this.oScore, this.turnCount, this.currentTurn, this.notation);
}

class GameLogic {
  static List<Coordinate> getImmediateMoves(int r, int c, PieceData p, [int? customRot]) {
    int rot = customRot ?? p.rotation;
    int shift = ((rot / 90) % 4).floor();
    var b = p.team == 'orange' ? [[1,0], [0,-1], [-1,0], [0,1]] : [[-1,0], [0,1], [1,0], [0,-1]];
    var v = {'up': b[shift], 'right': b[(shift+1)%4], 'down': b[(shift+2)%4], 'left': b[(shift+3)%4]};
    
    List<Coordinate> moves =[];
    void push(List<int> d) { int rr = r + d[0], cc = c + d[1]; if (rr >= 0 && rr < ROWS && cc >= 0 && cc < COLS) moves.add(Coordinate(rr, cc)); }
    List<int> add(List<int> a, List<int> b) => [a[0] + b[0], a[1] + b[1]];
    List<int> mul(List<int> a, int k) => [a[0] * k, a[1] * k];

    if (p.id == 'PR') { push(v['left']!); push(add(v['right']!, v['down']!)); }
    else if (p.id == 'PL') { push(v['right']!); push(add(v['left']!, v['down']!)); }
    else if (p.id == 'PX') { push(add(v['right']!, v['up']!)); push(add(v['right']!, v['down']!)); push(add(v['left']!, v['up']!)); push(add(v['left']!, v['down']!)); }
    else if (p.id == 'DP') { push(v['up']!); push(mul(v['up']!, 2)); push(v['left']!); push(v['right']!); }
    else if (p.id == 'DT') { push(v['up']!); push(add(v['up']!, v['left']!)); push(add(v['up']!, v['right']!)); push(v['down']!); }
    else if (p.id == 'DN') { push(v['up']!); push(v['down']!); push(mul(v['left']!, 2)); push(mul(v['right']!, 2)); }
    else if (p.id == 'C')  { push(v['up']!); push(add(v['down']!, v['left']!)); push(add(v['down']!, v['right']!)); }
    return moves;
  }

  static List<List<Set<Coordinate>>> getHighlightLayers(List<List<PieceData?>> board, int sr, int sc, [int? customRot]) {
    PieceData origin = board[sr][sc]!; Set<Coordinate> vPieces = {Coordinate(sr, sc)}, vPos = {};
    Set<Coordinate> currLayer = {Coordinate(sr, sc)}; List<List<Set<Coordinate>>> layers =[];

    while (currLayer.isNotEmpty) {
      Set<Coordinate> empty = {}, occupied = {}, next = {};
      for (var curr in currLayer) {
        bool isO = curr.r == sr && curr.c == sc;
        for (var t in getImmediateMoves(curr.r, curr.c, board[curr.r][curr.c]!, isO ? customRot : null)) {
          if (t == Coordinate(sr, sc) || vPos.contains(t)) continue;
          if (board[t.r][t.c] != null) {
            occupied.add(t);
            if (board[t.r][t.c]!.team == origin.team && !vPieces.contains(t)) { vPieces.add(t); next.add(t); }
          } else if (!isO) empty.add(t);
        }
      }
      if (empty.isNotEmpty || occupied.isNotEmpty) layers.add([empty, occupied]);
      vPos.addAll(empty); vPos.addAll(occupied); currLayer = next;
    }
    return layers;
  }

  static List<Coordinate> findPath(List<List<PieceData?>> board, int sr, int sc, int dr, int dc, [int? customRot]) {
    List<Map<String, dynamic>> queue = [{'pos': Coordinate(sr, sc), 'path': [Coordinate(sr, sc)]}];
    Set<Coordinate> visited = {Coordinate(sr, sc)};
    while (queue.isNotEmpty) {
      var curr = queue.removeAt(0); Coordinate pos = curr['pos']; List<Coordinate> path = List.from(curr['path']);
      for (var t in getImmediateMoves(pos.r, pos.c, board[pos.r][pos.c]!, (pos.r == sr && pos.c == sc) ? customRot : null)) {
        if (t.r == dr && t.c == dc) return path..add(t);
        if (board[t.r][t.c] != null && board[t.r][t.c]!.team == board[sr][sc]!.team && !visited.contains(t)) {
          visited.add(t); queue.add({'pos': t, 'path': List.from(path)..add(t)});
        }
      }
    }
    return[Coordinate(sr, sc), Coordinate(dr, dc)];
  }
}

class AIEngine {
  static List<List<PieceData?>> cloneBoard(List<List<PieceData?>> b) => b.map((r) => r.map((p) => p?.clone()).toList()).toList();
  static List<MoveAction> genMoves(List<List<PieceData?>> board, String team, int tCount) {
    List<MoveAction> moves =[];
    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        PieceData? p = board[r][c];
        if (p == null || p.team != team || p.immobilizedTurn > tCount) continue;
        for (int rot in (p.type == 'D' ? [0, 90, 180, 270] :[p.rotation])) {
          List<Coordinate> q = [Coordinate(r, c)]; Set<Coordinate> vis = {Coordinate(r, c)}; int head = 0;
          while (head < q.length) {
            Coordinate curr = q[head++];
            for (var t in GameLogic.getImmediateMoves(curr.r, curr.c, board[curr.r][curr.c]!, (curr.r == r && curr.c == c) ? rot : null)) {
              if (board[t.r][t.c] != null) {
                if (board[t.r][t.c]!.team != team) moves.add(MoveAction(Coordinate(r, c), t, true, rot, 1000 + (team == 'purple' ? 7 - t.r : t.r)));
                else if (!vis.contains(t)) { vis.add(t); q.add(t); }
              } else if (!vis.contains(t) && !(curr.r == r && curr.c == c)) {
                moves.add(MoveAction(Coordinate(r, c), t, false, rot, team == 'purple' ? 7 - t.r : t.r));
              }
            }
          }
        }
      }
    }
    moves.sort((a, b) => b.scoreVal.compareTo(a.scoreVal)); return moves;
  }

  static int eval(List<List<PieceData?>> b, String t, int pS, int oS, int tC) {
    Map<String, int> w = t == 'purple' ? PURPLE_WEIGHTS : ORANGE_WEIGHTS; int score = 0;
    if ((t == 'orange' ? oS : pS) >= WIN_SCORE) return w['WIN']!;
    if ((t == 'orange' ? pS : oS) >= WIN_SCORE) return -w['WIN']!;
    score += ((t == 'orange' ? oS : pS) - (t == 'orange' ? pS : oS)) * w['POINT']!;
    for (int r = 0; r < ROWS; r++) {
      for (int c = 0; c < COLS; c++) {
        if (b[r][c] == null) continue; PieceData p = b[r][c]!; bool isMe = p.team == t; int pos = 0;
        int val = p.type == 'P' ? w['PIECE_P']! : (p.type == 'D' ? w['PIECE_D']! : w['PIECE_C']!);
        if (p.type == 'P') {
          pos += (p.team == 'purple' ? 6 - r : r - 1) * (p.team == 'purple' ? 6 - r : r - 1) * w['ADVANCEMENT']!;
          if (!isMe && ((p.team == 'purple' && r == 1) || (p.team == 'orange' && r == 6))) score -= 5000;
        }
        if (c >= 2 && c <= 4) pos += w['CENTER_CONTROL']!;
        if (p.immobilizedTurn > tC) pos += isMe ? w['IMMOBILIZED_SELF']! : w['IMMOBILIZE_ENEMY']!;
        score += isMe ? (val + pos) : -(val + pos);
      }
    }
    return score;
  }

  static Map<String, int> applySim(List<List<PieceData?>> b, MoveAction m, int tC, int pS, int oS) {
    PieceData p = b[m.from.r][m.from.c]!.clone()..rotation = m.preMoveRotation; PieceData? t = b[m.to.r][m.to.c]?.clone();
    int add = 0; bool rm = false, rt = false;
    if (m.isSwap && p.type == 'C' && t?.type == 'C') { rt = true; add += 2; }
    if (p.type == 'P' && m.to.r == (p.team == 'purple' ? 0 : ROWS - 1)) { rm = true; if (p.id != 'PX' && add == 0) add = 1; }
    if (p.team == 'purple') pS += add; else oS += add;
    b[m.from.r][m.from.c] = (m.isSwap && !rt) ? (t!..immobilizedTurn = tC + 2) : null;
    b[m.to.r][m.to.c] = rm ? null : p;
    return {'p': pS, 'o': oS};
  }

  static int nodes = 0;
  static int minimax(List<List<PieceData?>> b, int d, int alpha, int beta, bool max, int tC, int pS, int oS, String botT, int sT, int maxT) {
    if (++nodes % 500 == 0 && DateTime.now().millisecondsSinceEpoch - sT > maxT) return eval(b, botT, pS, oS, tC);
    if (d == 0 || pS >= WIN_SCORE || oS >= WIN_SCORE) return eval(b, botT, pS, oS, tC);
    var moves = genMoves(b, max ? botT : (botT == 'purple' ? 'orange' : 'purple'), tC);
    if (moves.isEmpty) return eval(b, botT, pS, oS, tC);

    if (max) {
      int maxE = -99999999;
      for (var m in moves) {
        var res = applySim(cloneBoard(b), m, tC, pS, oS);
        int e = minimax(cloneBoard(b)..setAll(0, b), d - 1, alpha, beta, false, tC + 1, res['p']!, res['o']!, botT, sT, maxT);
        maxE = math.max(maxE, e); alpha = math.max(alpha, e); if (beta <= alpha) break;
      }
      return maxE;
    } else {
      int minE = 99999999;
      for (var m in moves) {
        var res = applySim(cloneBoard(b), m, tC, pS, oS);
        int e = minimax(cloneBoard(b)..setAll(0, b), d - 1, alpha, beta, true, tC + 1, res['p']!, res['o']!, botT, sT, maxT);
        minE = math.min(minE, e); beta = math.min(beta, e); if (beta <= alpha) break;
      }
      return minE;
    }
  }
}

class GyroadApp extends StatelessWidget {
  const GyroadApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false, theme: ThemeData(scaffoldBackgroundColor: bgColor, fontFamily: 'Georgia'),
    home: const GyroadGame(),
  );
}

class GyroadGame extends StatefulWidget { const GyroadGame({super.key}); @override State<GyroadGame> createState() => _GameState(); }

class _GameState extends State<GyroadGame> with TickerProviderStateMixin {
  List<List<PieceData?>> board =[]; int pScore = 0, oScore = 0, tCount = 1; String turn = 'purple', mode = 'bot', botT = 'orange';
  bool gameOver = false, isAnim = false, isLock = false, isRot = false; String? winMsg;
  Coordinate? selCell, wobCell; Set<Coordinate> avail = {}, swapAvail = {};
  int rotTurn = 0, origRot = 0, visRot = 0; int? rotId;
  List<GameSnapshot> hist = []; List<String> notation = [], expMoves =[]; int expIdx = 0, pUid = 0;
  bool showSet = false, showExp = false; int dP = 3, tP = 1000, dO = 3, tO = 1000;
  final TextEditingController _expCtrl = TextEditingController();

  late AnimationController _breatheCtrl, _moveCtrl, _wobbleCtrl;
  PieceData? _movingA, _movingB; Animation<Offset>? _animA, _animB; Coordinate? _destA;

  @override void initState() {
    super.initState();
    _breatheCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    _moveCtrl = AnimationController(vsync: this);
    _wobbleCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _wobbleCtrl.addListener(() => setState((){}));
    _initBoard();
  }
  @override void dispose() { _breatheCtrl.dispose(); _moveCtrl.dispose(); _wobbleCtrl.dispose(); super.dispose(); }

  void _initBoard() {
    board = List.generate(ROWS, (_) => List.filled(COLS, null)); pUid = 0;
    const pSet =[Coordinate(6,0),Coordinate(6,1),Coordinate(6,2),Coordinate(6,3),Coordinate(6,4),Coordinate(6,5),Coordinate(6,6),Coordinate(7,0),Coordinate(7,1),Coordinate(7,2),Coordinate(7,3),Coordinate(7,4),Coordinate(7,5),Coordinate(7,6)];
    const pIds =['PR','PL','PR','PX','PL','PR','PL','DP','DT','DN','C','DN','DT','DP'];
    for (int i=0; i<pSet.length; i++) board[pSet[i].r][pSet[i].c] = PieceData(id: pIds[i], type: CONFIG_BY_ID[pIds[i]]!.type, team: 'purple', uid: pUid++);
    const oSet =[Coordinate(1,0),Coordinate(1,1),Coordinate(1,2),Coordinate(1,3),Coordinate(1,4),Coordinate(1,5),Coordinate(1,6),Coordinate(0,0),Coordinate(0,1),Coordinate(0,2),Coordinate(0,3),Coordinate(0,4),Coordinate(0,5),Coordinate(0,6)];
    const oIds =['PL','PR','PL','PX','PR','PL','PR','DP','DT','DN','C','DN','DT','DP'];
    for (int i=0; i<oSet.length; i++) board[oSet[i].r][oSet[i].c] = PieceData(id: oIds[i], type: CONFIG_BY_ID[oIds[i]]!.type, team: 'orange', uid: pUid++);
    if ((mode == 'bot' && turn == botT) || mode == 'bot-vs-bot') _execBot();
  }

  void _reset() => setState(() { selCell = wobCell = null; isAnim = isLock = isRot = gameOver = false; turn = 'purple'; tCount = 1; pScore = oScore = rotTurn = 0; rotId = null; hist.clear(); avail.clear(); swapAvail.clear(); if (mode != 'explorer' || expIdx == 0) notation.clear(); _initBoard(); });
  void _save() { hist.add(GameSnapshot(AIEngine.cloneBoard(board), pScore, oScore, tCount, turn, List.from(notation))); if (hist.length > 100) hist.removeAt(0); }
  void _undo() {
    if (isAnim || gameOver || hist.isEmpty) return;
    GameSnapshot? t; if (mode == 'explorer' || mode == '2-player') t = hist.removeLast(); else if (hist.length >= 2) { hist.removeLast(); t = hist.removeLast(); } else if (hist.length == 1) t = hist.removeLast();
    if (t != null) setState(() { board = AIEngine.cloneBoard(t!.board); pScore = t.pScore; oScore = t.oScore; tCount = t.turnCount; turn = t.currentTurn; notation = List.from(t.notation); rotTurn = 0; rotId = null; _clear(); });
  }

  void _clear() { avail.clear(); swapAvail.clear(); isRot = false; selCell = null; }
  void _wobble(Coordinate c) { wobCell = c; _wobbleCtrl.forward(from: 0).then((_) => setState(() => wobCell = null)); }

  Future<void> _execMove(Coordinate f, Coordinate t, bool isSwap, int? rot, double cW, double gap) async {
    if (isAnim) return; _save();
    PieceData pA = board[f.r][f.c]!; PieceData? pB = isSwap ? board[t.r][t.c] : null;
    if (mode != 'explorer') notation.add('${pA.id}${String.fromCharCode(97+f.c)}${8-f.r}${rot != null && rot != pA.rotation ? 'R$rot' : ''}${isSwap ? 'x' : '-'}${String.fromCharCode(97+t.c)}${8-t.r}');

    setState(() {
      isAnim = isLock = true; if (rot != null) pA.rotation = rot; _clear();
      board[f.r][f.c] = null; if (isSwap) board[t.r][t.c] = null;
      _movingA = pA; _movingB = pB; _destA = t;
    });

    List<Coordinate> path = GameLogic.findPath(board, f.r, f.c, t.r, t.c, rot);
    if (path.length == 1) path.add(t); // Failsafe
    List<TweenSequenceItem<Offset>> seq =[];
    Offset getP(Coordinate c) => Offset(gap + c.c * (cW + gap), gap + c.r * (cW + gap));
    for (int i = 0; i < path.length - 1; i++) seq.add(TweenSequenceItem(tween: Tween(begin: getP(path[i]), end: getP(path[i+1])), weight: 1.0));
    _animA = TweenSequence(seq).animate(CurvedAnimation(parent: _moveCtrl, curve: Curves.easeInOut));
    if (isSwap) _animB = Tween(begin: getP(t), end: getP(f)).animate(CurvedAnimation(parent: _moveCtrl, curve: Curves.easeInOut));

    _moveCtrl.duration = Duration(milliseconds: STEP_DURATION_MS * (path.length - 1));
    await _moveCtrl.forward(from: 0);

    int sAdd = 0; bool rmA = false, rmB = false;
    if (isSwap && pA.type == 'C' && pB?.type == 'C') { rmB = true; sAdd += 2; }
    if (pA.type == 'P' && t.r == (pA.team == 'purple' ? 0 : ROWS - 1)) { rmA = true; if (pA.id != 'PX' && sAdd == 0) sAdd = 1; }

    setState(() {
      _movingA = _movingB = _animA = _animB = _destA = null;
      if (!rmA) board[t.r][t.c] = pA;
      if (isSwap && !rmB) { board[f.r][f.c] = pB; if (pA.team != pB!.team) pB.immobilizedTurn = tCount + 2; }
      if (turn == 'purple') pScore += sAdd; else oScore += sAdd;
      if (pScore >= WIN_SCORE || oScore >= WIN_SCORE) { gameOver = true; isLock = true; winMsg = '${pScore >= WIN_SCORE ? 'Purple' : 'Orange'} Wins!'; if(mode == 'bot-vs-bot') Future.delayed(const Duration(seconds: 4), _reset); }
      isAnim = false; if (!gameOver) isLock = false;
    });
    if (!gameOver) _switchTurn();
  }

  Future<void> _switchTurn() async {
    setState(() {
      tCount++; turn = turn == 'purple' ? 'orange' : 'purple'; rotTurn = 0; rotId = null;
      for (int r = 0; r < ROWS; r++) for (int c = 0; c < COLS; c++) if (board[r][c] != null && board[r][c]!.team == turn && tCount >= board[r][c]!.immobilizedTurn) board[r][c]!.immobilizedTurn = 0;
    });
    bool hasMoves = false;
    for (int r = 0; r < ROWS; r++) for (int c = 0; c < COLS; c++) if (board[r][c] != null && board[r][c]!.team == turn && board[r][c]!.immobilizedTurn <= tCount && GameLogic.getHighlightLayers(board, r, c).isNotEmpty) hasMoves = true;
    if (!hasMoves) { setState(() { gameOver = isLock = true; winMsg = '${turn == 'purple' ? 'Orange' : 'Purple'} Wins!'; }); return; }
    if ((mode == 'bot' && turn == botT) || mode == 'bot-vs-bot') await _execBot();
  }

  Future<void> _execBot() async {
    setState(() => isLock = true); await Future.delayed(const Duration(milliseconds: 500)); if (gameOver) return;
    int sT = DateTime.now().millisecondsSinceEpoch, maxT = turn == 'purple' ? tP : tO; AIEngine.nodes = 0;
    var moves = AIEngine.genMoves(board, turn, tCount); if (moves.isEmpty) return _switchTurn();
    MoveAction bestM = moves[0]; int bestV = -99999999, alpha = -99999999, beta = 99999999;
    for (var m in moves) {
      if (DateTime.now().millisecondsSinceEpoch - sT > maxT) break;
      var res = AIEngine.applySim(AIEngine.cloneBoard(board), m, tCount, pScore, oScore);
      int val = AIEngine.minimax(AIEngine.cloneBoard(board), (turn == 'purple' ? dP : dO) - 1, alpha, beta, false, tCount + 1, res['p']!, res['o']!, turn, sT, maxT);
      if (val > bestV) { bestV = val; bestM = m; } alpha = math.max(alpha, bestV);
    }
    await _execMove(bestM.from, bestM.to, bestM.isSwap, bestM.preMoveRotation, _cW, _gap);
  }

  double _cW = 0, _gap = 0;
  void _click(int r, int c) {
    if (isLock || gameOver || (mode == 'bot' && turn == botT) || mode == 'bot-vs-bot' || mode == 'explorer') return;
    Coordinate clicked = Coordinate(r, c);
    if (isRot) { if (selCell == clicked) setState(() => visRot = (visRot + 90) % 360); return; }
    if (selCell != null && (avail.contains(clicked) || swapAvail.contains(clicked))) { _execMove(selCell!, clicked, swapAvail.contains(clicked), null, _cW, _gap); return; }
    PieceData? p = board[r][c];
    if (p != null && p.team == turn && p.immobilizedTurn <= tCount) {
      if (selCell == clicked) setState(() => _clear());
      else {
        setState(() { _clear(); selCell = clicked; if (p.type == 'D' && rotTurn < 2 && p.uid != rotId) isRot = true; visRot = origRot = p.rotation; });
        _showLayers(r, c);
      }
    } else { setState(() => _clear()); _wobble(clicked); }
  }

  void _showLayers(int r, int c) async {
    var layers = GameLogic.getHighlightLayers(board, r, c);
    for (var l in layers) { await Future.delayed(const Duration(milliseconds: LAYER_DELAY_MS)); if (!mounted || selCell?.r != r || selCell?.c != c) break; setState(() { avail.addAll(l[0]); swapAvail.addAll(l[1]); }); }
  }

  void _rotOut(bool ok) {
    if (!isRot || selCell == null) return;
    setState(() {
      if (ok && visRot != origRot) { rotTurn++; rotId = board[selCell!.r][selCell!.c]!.uid; board[selCell!.r][selCell!.c]!.rotation = visRot; }
      isRot = false; _showLayers(selCell!.r, selCell!.c);
    });
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children:[
        SafeArea(child: Column(children:[
          _scores(),
          Expanded(child: LayoutBuilder(builder: (c, cons) {
            _gap = cons.maxWidth * 0.015; _cW = (cons.maxWidth - (COLS + 1) * _gap) / COLS;
            if (_cW * ROWS + _gap * (ROWS + 1) > cons.maxHeight - 60) _cW = (cons.maxHeight - 60 - _gap * (ROWS + 1)) / ROWS;
            double bW = _cW * COLS + _gap * (COLS + 1), bH = _cW * ROWS + _gap * (ROWS + 1);
            return Center(child: SizedBox(width: bW, height: bH, child: Stack(clipBehavior: Clip.none, children:[
              Container(decoration: BoxDecoration(color: boardBg, border: Border.all(color: turn == 'purple' ? purpleTheme.color : orangeTheme.color, width: 3), boxShadow: const[BoxShadow(color: Colors.black54, blurRadius: 20)])),
              ...List.generate(ROWS * COLS, (i) {
                int r = i ~/ COLS, c = i % COLS; Coordinate coord = Coordinate(r, c);
                bool s = selCell == coord, a = avail.contains(coord), sw = swapAvail.contains(coord), w = wobCell == coord;
                double dx = 0; Color? sC;
                if (w) {
                  double t = _wobbleCtrl.value;
                  if (t < 0.2) dx = -5.0 * (t / 0.2); else if (t < 0.4) dx = -5.0 + 10.0 * ((t - 0.2) / 0.2); else if (t < 0.6) dx = 5.0 - 8.0 * ((t - 0.4) / 0.2); else if (t < 0.8) dx = -3.0 + 6.0 * ((t - 0.6) / 0.2); else dx = 3.0 - 3.0 * ((t - 0.8) / 0.2);
                  sC = Colors.redAccent.withOpacity(math.sin(t * math.pi));
                }
                return Positioned(left: _gap + c * (_cW + _gap), top: _gap + r * (_cW + _gap), width: _cW, height: _cW, child: GestureDetector(
                  onTap: () => _click(r, c),
                  child: Transform.translate(offset: Offset(dx, 0), child: AnimatedBuilder(animation: _breatheCtrl, builder: (ctx, _) {
                    double bR = s || a || sw ? ui.lerpDouble(7, 25, _breatheCtrl.value)! : 0;
                    return Container(decoration: BoxDecoration(color: s ? selectedColor : (a ? availableColor : (sw ? swapColor : cellColor)), boxShadow: s || a || sw || w ?[BoxShadow(color: w ? sC! : (s ? selectedColor : (sw ? swapColor : availableColor)), blurRadius: w ? 8 : bR)] : null));
                  })),
                ));
              }),
              ..._buildStaticPieces(),
              if (_movingA != null && _animA != null) AnimatedBuilder(animation: _animA!, builder: (ctx, _) => Positioned(left: _animA!.value.dx, top: _animA!.value.dy, width: _cW, height: _cW, child: CustomPaint(painter: PiecePainter(_movingA!, false, false, 1.0)))),
              if (_movingB != null && _animB != null) AnimatedBuilder(animation: _animB!, builder: (ctx, _) => Positioned(left: _animB!.value.dx, top: _animB!.value.dy, width: _cW, height: _cW, child: CustomPaint(painter: PiecePainter(_movingB!, false, false, 1.0)))),
              if (isRot && selCell != null) Positioned(left: _gap + selCell!.c * (_cW + _gap) - _cW * 0.5, top: _gap + selCell!.r * (_cW + _gap) - _cW * 1.2, child: _rotMenu()),
              if (gameOver) Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), decoration: BoxDecoration(color: const Color(0xF11A1A1A), borderRadius: BorderRadius.circular(10), border: Border.all(color: borderColor, width: 2)), child: Text(winMsg!, style: TextStyle(fontSize: 32, color: Colors.white, shadows:[BoxShadow(color: winMsg!.contains('Purple') ? purpleTheme.color : orangeTheme.color, blurRadius: 15)])))),
            ])));
          })),
          _notation(),
        ])),
        Positioned(bottom: 15, left: MediaQuery.of(context).size.width / 2 - 25, child: FloatingActionButton(heroTag: 'set', backgroundColor: const Color(0xFF6A5A87), onPressed: () => setState(() => showSet = true), child: const Icon(Icons.settings))),
        if (mode != 'bot-vs-bot' && mode != 'explorer' && hist.isNotEmpty) Positioned(bottom: 15, right: 20, child: FloatingActionButton(heroTag: 'un', backgroundColor: const Color(0xFF6A5A87), onPressed: _undo, child: const Icon(Icons.undo))),
        if (showSet) _settings(), if (showExp) _explorer(),
      ]),
    );
  }

  List<Widget> _buildStaticPieces() {
    List<Widget> w =[];
    for (int r = 0; r < ROWS; r++) for (int c = 0; c < COLS; c++) {
      if (board[r][c] != null) {
        bool s = selCell?.r == r && selCell?.c == c;
        w.add(Positioned(left: _gap + c * (_cW + _gap), top: _gap + r * (_cW + _gap), width: _cW, height: _cW, child: IgnorePointer(
          child: AnimatedBuilder(animation: _breatheCtrl, builder: (ctx, _) => CustomPaint(painter: PiecePainter(board[r][c]!..rotation = (isRot && s) ? visRot : board[r][c]!.rotation, s, board[r][c]!.immobilizedTurn > tCount, s ? 1.05 : 1.0, s ? _breatheCtrl.value : 0.0))),
        )));
      }
    }
    return w;
  }

  Widget _scores() => Padding(padding: const EdgeInsets.all(15), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children:[
    Row(children: List.generate(WIN_SCORE, (i) => Container(width: 25, height: 10, margin: const EdgeInsets.only(right: 4), decoration: BoxDecoration(border: Border.all(color: purpleTheme.color, width: 2), color: i < pScore ? purpleTheme.color : Colors.transparent, boxShadow: i < pScore ? [BoxShadow(color: purpleTheme.color, blurRadius: 5)] : null)))),
    Row(children: List.generate(WIN_SCORE, (i) => Container(width: 25, height: 10, margin: const EdgeInsets.only(left: 4), decoration: BoxDecoration(border: Border.all(color: orangeTheme.color, width: 2), color: i < oScore ? orangeTheme.color : Colors.transparent, boxShadow: i < oScore ?[BoxShadow(color: orangeTheme.color, blurRadius: 5)] : null)))),
  ]));

  Widget _rotMenu() => Row(children:[
    IconButton(icon: const Icon(Icons.check, color: Colors.white), style: IconButton.styleFrom(backgroundColor: selectedColor, shape: const CircleBorder()), onPressed: () => _rotOut(true)),
    const SizedBox(width: 10),
    IconButton(icon: const Icon(Icons.close, color: Colors.white), style: IconButton.styleFrom(backgroundColor: const Color(0xFF6A5A87), shape: const CircleBorder()), onPressed: () => _rotOut(false)),
  ]);

  Widget _notation() {
    String txt = notation.isEmpty ? 'Game Start' : List.generate((notation.length / 2).ceil(), (i) => '${i + 1}. ${notation[i * 2]}${i * 2 + 1 < notation.length ? ' ${notation[i * 2 + 1]}' : ''}').join('   ');
    return Container(margin: const EdgeInsets.fromLTRB(10, 0, 10, 80), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white10, border: Border.all(color: borderColor)), child: Row(children:[
      Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: Text(txt, style: const TextStyle(fontFamily: 'monospace', color: Colors.white70)))),
      const SizedBox(width: 10),
      if (mode != 'explorer') ...[_btn('Copy', () => Clipboard.setData(ClipboardData(text: txt))), const SizedBox(width: 5), _btn('Explorer', () => setState(() => showExp = true))]
      else ...[_btn('<', _undo), const SizedBox(width: 5), _btn('>', () async { if (isAnim || expIdx >= expMoves.length) return; var m = RegExp(r'^([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])$').firstMatch(expMoves[expIdx]); if (m == null) return; Coordinate f = Coordinate(8 - int.parse(m.group(2)![1]), m.group(2)!.codeUnitAt(0) - 97), t = Coordinate(8 - int.parse(m.group(5)![1]), m.group(5)!.codeUnitAt(0) - 97); setState(() { notation.add(expMoves[expIdx]); }); await _execMove(f, t, m.group(4) == 'x', m.group(3) != null ? int.parse(m.group(3)!) : null, _cW, _gap); setState(() => expIdx++); }), const SizedBox(width: 5), _btn('Exit', () => setState(() { mode = 'bot'; _reset(); }))]
    ]));
  }

  Widget _btn(String lbl, VoidCallback cb) => InkWell(onTap: cb, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF6A5A87), Color(0xFF3B314A)]), border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(3)), child: Text(lbl, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic, color: Colors.white))));

  Widget _settings() => Container(color: Colors.black87, child: Center(child: Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF1A1A1C), border: Border.all(color: borderColor)), child: Column(mainAxisSize: MainAxisSize.min, children:[
    const Text('Game Mode', style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)), const SizedBox(height: 10),
    ...['2-player', 'bot', 'bot-vs-bot'].map((m) => Padding(padding: const EdgeInsets.only(bottom: 5), child: SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: mode == m ? selectedColor : const Color(0xFF3B314A), shape: const RoundedRectangleBorder()), onPressed: () => setState(() { mode = m; if (m == 'bot') botT = 'orange'; showSet = false; _reset(); }), child: Text(m, style: const TextStyle(color: Colors.white)))))),
    const Divider(color: Colors.white24, height: 20),
    _sld('P Depth: $dP', dP.toDouble(), 1, 5, (v) => setState(() => dP = v.toInt())), _sld('P Time: $tP', tP.toDouble(), 100, 3000, (v) => setState(() => tP = v.toInt())),
    _sld('O Depth: $dO', dO.toDouble(), 1, 5, (v) => setState(() => dO = v.toInt())), _sld('O Time: $tO', tO.toDouble(), 100, 3000, (v) => setState(() => tO = v.toInt())),
    const SizedBox(height: 10), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]), onPressed: () => setState(() => showSet = false), child: const Text('Close', style: TextStyle(color: Colors.white)))
  ]))));

  Widget _sld(String l, double v, double min, double max, Function(double) cb) => Column(crossAxisAlignment: CrossAxisAlignment.start, children:[Text(l, style: const TextStyle(fontSize: 12, color: Colors.white)), Slider(value: v, min: min, max: max, activeColor: selectedColor, onChanged: cb)]);

  Widget _explorer() => Container(color: Colors.black87, child: Center(child: Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF1A1A1C), border: Border.all(color: borderColor)), child: Column(mainAxisSize: MainAxisSize.min, children:[
    const Text('Game Explorer', style: TextStyle(fontSize: 20, color: Colors.white)), const SizedBox(height: 10),
    TextField(controller: _expCtrl, maxLines: 5, style: const TextStyle(fontFamily: 'monospace', color: Colors.white), decoration: const InputDecoration(hintText: 'Paste notation...', filled: true, fillColor: Colors.black54, border: OutlineInputBorder())), const SizedBox(height: 10),
    SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: selectedColor), onPressed: () { var m = RegExp(r'([A-Z]{1,2})([a-g][1-8])(?:R(\d+))?([x\-])([a-g][1-8])').allMatches(_expCtrl.text); if (m.isEmpty) return; setState(() { expMoves = m.map((e) => e.group(0)!).toList(); mode = 'explorer'; expIdx = 0; showExp = false; _reset(); }); }, child: const Text('Load Game', style: TextStyle(color: Colors.white)))),
    SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]), onPressed: () => setState(() => showExp = false), child: const Text('Cancel', style: TextStyle(color: Colors.white))))
  ]))));
}

class PiecePainter extends CustomPainter {
  final PieceData p; final bool sel, imm; final double scl, br;
  PiecePainter(this.p, this.sel, this.imm, this.scl, [this.br = 0]);
  @override void paint(Canvas c, Size s) {
    if (imm) c.saveLayer(Offset.zero & s, Paint()..colorFilter = const ColorFilter.matrix([0.21, 0.71, 0.07, 0, 0, 0.21, 0.71, 0.07, 0, 0, 0.21, 0.71, 0.07, 0, 0, 0, 0, 0, 1, 0]));
    double cx = s.width / 2, cy = s.height / 2, cw = s.width;
    c.translate(cx, cy); c.rotate((p.team == 'orange' ? 180 + p.rotation : p.rotation) * math.pi / 180); c.scale(scl); c.translate(-cx, -cy);
    var th = p.team == 'purple' ? purpleTheme : orangeTheme; var conf = CONFIG_BY_ID[p.id]!;
    
    for (String dir in conf.directions) {
      c.save(); c.translate(cx, cy); c.rotate({'n':0.0, 'ne':45.0, 'e':90.0, 'se':135.0, 's':180.0, 'sw':225.0, 'w':270.0, 'nw':315.0}[dir]! * math.pi / 180);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, -cw * 0.21), width: cw * 0.06, height: cw * 0.42), const Radius.circular(2)), Paint()..shader = ui.Gradient.linear(Offset(0, -cw * 0.42), const Offset(0, 0),[metalShadowColor, const Color(0xFF2A2E37)]));
      bool jmp = conf.jumpDirections.contains(dir), pwr = p.id == 'DP' && dir == 'n';
      Paint nBg = Paint(), nBord = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0;
      if (sel && !jmp && !pwr) { nBg.shader = ui.Gradient.radial(Offset(-cw * 0.02, -cw * 0.375), cw * 0.1,[th.glow, th.color]); nBord.color = th.glow; c.drawCircle(Offset(0, -cw * 0.355), cw * 0.085, Paint()..color = th.color..maskFilter = MaskFilter.blur(BlurStyle.outer, ui.lerpDouble(10, 15, br)!)); }
      else if (sel && jmp) { nBg.shader = ui.Gradient.radial(Offset(0, -cw * 0.355), cw * 0.085,[metalShadowColor, Colors.black]); nBord.color = th.glow; c.drawCircle(Offset(0, -cw * 0.355), cw * 0.085, Paint()..color = th.color..maskFilter = MaskFilter.blur(BlurStyle.outer, ui.lerpDouble(10, 15, br)!)); }
      else if (sel && pwr) { nBg.shader = ui.Gradient.radial(Offset(-cw * 0.01, -cw * 0.365), cw * 0.085,[Colors.white, th.glow, th.color], [0, 0.55, 1]); nBord.color = Colors.white; c.drawCircle(Offset(0, -cw * 0.355), cw * 0.085, Paint()..color = th.color..maskFilter = MaskFilter.blur(BlurStyle.outer, ui.lerpDouble(10, 15, br)!)); }
      else { nBg.shader = ui.Gradient.radial(Offset(-cw * 0.02, -cw * 0.375), cw * 0.1, [metalHighlightColor, metalBaseColor]); nBord.color = metalShadowColor; }
      c.drawCircle(Offset(0, -cw * 0.355), cw * 0.085, nBg); c.drawCircle(Offset(0, -cw * 0.355), cw * 0.085, nBord);
      c.restore();
    }

    double cs = p.type == 'D' ? 0.25 : (p.type == 'C' ? 0.40 : 0.20); Rect cr = Rect.fromCenter(center: Offset(cx, cy), width: cw * cs, height: cw * cs);
    Paint cBg = Paint()..shader = ui.Gradient.linear(cr.topLeft, cr.bottomRight, [metalHighlightColor, metalBaseColor]), cBd = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.0..color = metalShadowColor;
    c.save(); if (p.type == 'D') { c.translate(cx, cy); c.rotate(45 * math.pi / 180); c.translate(-cx, -cy); c.drawRect(cr, cBg); c.drawRect(cr, cBd); } else { c.drawCircle(Offset(cx, cy), cw * cs / 2, cBg); c.drawCircle(Offset(cx, cy), cw * cs / 2, cBd); } c.restore();
    
    double gs = cs * 0.6; Rect gr = Rect.fromCenter(center: Offset(cx, cy), width: cw * gs, height: cw * gs);
    Paint gBg = Paint()..shader = ui.Gradient.radial(Offset(cx - gr.width * 0.2, cy - gr.height * 0.2), gr.width, [th.glow, th.color]);
    if (sel) c.drawCircle(Offset(cx, cy), gr.width / 2, Paint()..color = th.color..maskFilter = MaskFilter.blur(BlurStyle.outer, ui.lerpDouble(12, 18, br)!));
    c.save(); if (p.type == 'D') { c.translate(cx, cy); c.rotate(45 * math.pi / 180); c.translate(-cx, -cy); c.drawRRect(RRect.fromRectAndRadius(gr, const Radius.circular(2)), gBg); } else { c.drawCircle(Offset(cx, cy), cw * gs / 2, gBg); } c.restore();
    if (imm) c.restore();
  }
  @override bool shouldRepaint(PiecePainter o) => o.p != p || o.sel != sel || o.imm != imm || o.scl != scl || o.br != br;
}
