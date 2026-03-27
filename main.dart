import 'package:flutter/material.dart';
import 'dart:math';

void main() {
  runApp(const GyroadApp());
}

class GyroadApp extends StatelessWidget {
  const GyroadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GYROAD Native',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        brightness: Brightness.dark,
      ),
      home: const GameBoard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum Team { purple, orange }
enum PieceType { diamond, circle, point }

class Piece {
  final String id;
  final Team team;
  final PieceType type;
  int rotation;

  Piece({required this.id, required this.team, required this.type, this.rotation = 0});
}

class GameBoard extends StatefulWidget {
  const GameBoard({super.key});

  @override
  State<GameBoard> createState() => _GameBoardState();
}

class _GameBoardState extends State<GameBoard> {
  static const int rows = 8;
  static const int cols = 7;
  
  late List<List<Piece?>> board;
  Team currentTurn = Team.purple;
  int purpleScore = 0;
  int orangeScore = 0;
  List<int>? selectedCell;
  List<List<int>> availableMoves = [];

  final Color purpleNeon = const Color(0xFFA87CFF);
  final Color orangeNeon = const Color(0xFFFF6B6B);
  final Color cellBg = const Color(0xFF584A73);

  @override
  void initState() {
    super.initState();
    _initializeBoard();
  }

  void _initializeBoard() {
    board = List.generate(rows, (_) => List.filled(cols, null));
    
    // Setup Purple
    _placePiece(6, 0, 'PR', Team.purple, PieceType.point);
    _placePiece(6, 1, 'PL', Team.purple, PieceType.point);
    _placePiece(6, 3, 'PX', Team.purple, PieceType.point);
    _placePiece(7, 0, 'DP', Team.purple, PieceType.diamond);
    _placePiece(7, 3, 'C', Team.purple, PieceType.circle);
    
    // Setup Orange (rotated)
    _placePiece(1, 0, 'PL', Team.orange, PieceType.point, rot: 180);
    _placePiece(1, 1, 'PR', Team.orange, PieceType.point, rot: 180);
    _placePiece(1, 3, 'PX', Team.orange, PieceType.point, rot: 180);
    _placePiece(0, 0, 'DP', Team.orange, PieceType.diamond, rot: 180);
    _placePiece(0, 3, 'C', Team.orange, PieceType.circle, rot: 180);
  }

  void _placePiece(int r, int c, String id, Team t, PieceType type, {int rot = 0}) {
    board[r][c] = Piece(id: id, team: t, type: type, rotation: rot);
  }

  void _handleCellTap(int r, int c) {
    if (board[r][c]?.team == currentTurn) {
      setState(() {
        selectedCell = [r, c];
        availableMoves = _calculateDummyMoves(r, c); // Placeholder for immediate pathing
      });
    } else if (selectedCell != null) {
      bool isValidMove = availableMoves.any((m) => m[0] == r && m[1] == c);
      if (isValidMove) {
        _executeMove(selectedCell![0], selectedCell![1], r, c);
      } else {
        setState(() { selectedCell = null; availableMoves = []; });
      }
    }
  }

  List<List<int>> _calculateDummyMoves(int r, int c) {
    // Simplified movement logic for first build to ensure compilation
    List<List<int>> moves = [];
    int dir = board[r][c]!.team == Team.purple ? -1 : 1;
    if (r + dir >= 0 && r + dir < rows) moves.add([r + dir, c]); // Move forward
    if (r + dir >= 0 && r + dir < rows && c - 1 >= 0) moves.add([r + dir, c - 1]); // Diagonal
    if (r + dir >= 0 && r + dir < rows && c + 1 < cols) moves.add([r + dir, c + 1]); // Diagonal
    return moves;
  }

  void _executeMove(int sr, int sc, int dr, int dc) {
    setState(() {
      board[dr][dc] = board[sr][sc];
      board[sr][sc] = null;
      selectedCell = null;
      availableMoves = [];
      currentTurn = currentTurn == Team.purple ? Team.orange : Team.purple;
    });
    
    if (currentTurn == Team.orange) {
      Future.delayed(const Duration(milliseconds: 600), _botTurn);
    }
  }

  void _botTurn() {
    // Basic placeholder bot. The massive Minimax tree will replace this.
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        if (board[r][c]?.team == Team.orange) {
          var moves = _calculateDummyMoves(r, c);
          if (moves.isNotEmpty) {
            _executeMove(r, c, moves.first[0], moves.first[1]);
            return;
          }
        }
      }
    }
  }

  Widget _buildPiece(Piece piece) {
    Color glowColor = piece.team == Team.purple ? purpleNeon : orangeNeon;
    
    return Transform.rotate(
      angle: piece.rotation * (pi / 180),
      child: Center(
        child: Container(
          width: piece.type == PieceType.circle ? 30 : 20,
          height: piece.type == PieceType.circle ? 30 : 20,
          decoration: BoxDecoration(
            shape: piece.type == PieceType.circle ? BoxShape.circle : BoxShape.rectangle,
            color: const Color(0xFF9AA0B8),
            boxShadow: [
              BoxShadow(color: glowColor.withOpacity(0.8), blurRadius: 10, spreadRadius: 2)
            ]
          ),
          child: Transform.rotate(
            angle: piece.type == PieceType.diamond ? pi / 4 : 0,
            child: Container(
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: piece.type == PieceType.circle ? BoxShape.circle : BoxShape.rectangle,
                gradient: RadialGradient(
                  colors: [glowColor, glowColor.withOpacity(0.5)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Purple: $purpleScore", style: TextStyle(color: purpleNeon, fontSize: 20, fontWeight: FontWeight.bold)),
                  Text("Orange: $orangeScore", style: TextStyle(color: orangeNeon, fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: cols / rows,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: currentTurn == Team.purple ? purpleNeon : orangeNeon, width: 3),
                      color: const Color(0xFF2A2235),
                    ),
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: 2,
                        mainAxisSpacing: 2,
                      ),
                      itemCount: rows * cols,
                      itemBuilder: (context, index) {
                        int r = index ~/ cols;
                        int c = index % cols;
                        bool isSelected = selectedCell?[0] == r && selectedCell?[1] == c;
                        bool isAvailable = availableMoves.any((m) => m[0] == r && m[1] == c);

                        return GestureDetector(
                          onTap: () => _handleCellTap(r, c),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF9370DB) : 
                                     isAvailable ? const Color(0xFFD8B4FE) : cellBg,
                              border: Border.all(color: Colors.black12),
                              boxShadow: isSelected ? [BoxShadow(color: purpleNeon, blurRadius: 15)] : [],
                            ),
                            child: board[r][c] != null ? _buildPiece(board[r][c]!) : null,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                "${currentTurn == Team.purple ? "Purple" : "Orange"}'s Turn",
                style: TextStyle(
                  color: currentTurn == Team.purple ? purpleNeon : orangeNeon,
                  fontSize: 24,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
