import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

// -----------------------------
// Models
// -----------------------------
class WorkoutSet {
  int id;
  int workoutId;
  int setIndex; // 0-based
  int reps;
  bool done;

  WorkoutSet({
    this.id = 0,
    required this.workoutId,
    required this.setIndex,
    required this.reps,
    this.done = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'workoutId': workoutId,
    'setIndex': setIndex,
    'reps': reps,
    'done': done ? 1 : 0,
  };

  static WorkoutSet fromMap(Map<String, dynamic> m) {
    return WorkoutSet(
      id: m['id'] as int,
      workoutId: m['workoutId'] as int,
      setIndex: m['setIndex'] as int,
      reps: m['reps'] as int,
      done: (m['done'] as int) == 1,
    );
  }
}

class Workout {
  int id;
  String date; // yyyy-mm-dd
  String name;
  int sets;
  int reps;
  String comment;

  Workout({
    this.id = 0,
    required this.date,
    required this.name,
    required this.sets,
    required this.reps,
    this.comment = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'date': date,
    'name': name,
    'sets': sets,
    'reps': reps,
    'comment': comment,
  };

  static Workout fromMap(Map<String, dynamic> m) {
    return Workout(
      id: m['id'] as int,
      date: m['date'] as String,
      name: m['name'] as String,
      sets: m['sets'] as int,
      reps: m['reps'] as int,
      comment: m['comment'] as String,
    );
  }
}

// -----------------------------
// Database helper
// -----------------------------
class DBHelper {
  static final DBHelper _instance = DBHelper._internal();
  factory DBHelper() => _instance;
  DBHelper._internal();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = p.join(documentsDirectory.path, "workouts.db");
    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE workouts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT,
        name TEXT,
        sets INTEGER,
        reps INTEGER,
        comment TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE sets(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workoutId INTEGER,
        setIndex INTEGER,
        reps INTEGER,
        done INTEGER
      )
    ''');
  }

  Future<int> insertWorkout(Workout w) async {
    final database = await db;
    return await database.transaction<int>((txn) async {
      int id = await txn.insert('workouts', w.toMap());
      for (int i = 0; i < w.sets; i++) {
        await txn.insert('sets', {
          'workoutId': id,
          'setIndex': i,
          'reps': w.reps,
          'done': 0,
        });
      }
      return id;
    });
  }

  Future<List<Workout>> getWorkoutsByDate(String date) async {
    final database = await db;
    final res = await database.query(
      'workouts',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'id DESC',
    );
    return res.map((e) => Workout.fromMap(e)).toList();
  }

  Future<List<WorkoutSet>> getSetsByWorkout(int workoutId) async {
    final database = await db;
    final res = await database.query(
      'sets',
      where: 'workoutId = ?',
      whereArgs: [workoutId],
      orderBy: 'setIndex ASC',
    );
    return res.map((e) => WorkoutSet.fromMap(e)).toList();
  }

  Future<void> updateSet(WorkoutSet s) async {
    final database = await db;
    await database.update('sets', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> deleteWorkout(int id) async {
    final database = await db;
    await database.delete('sets', where: 'workoutId = ?', whereArgs: [id]);
    await database.delete('workouts', where: 'id = ?', whereArgs: [id]);
  }
}

// -----------------------------
// Provider for app state
// -----------------------------
class WorkoutProvider extends ChangeNotifier {
  String selectedDate = _formatDate(DateTime.now());
  Map<int, List<WorkoutSet>> setsCache = {};
  List<Workout> workouts = [];

  final DBHelper db = DBHelper();

  WorkoutProvider() {
    Future.microtask(() => loadWorkoutsForSelectedDate());
  }

  static String _formatDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  void selectDate(DateTime dt) {
    selectedDate = _formatDate(dt);
    loadWorkoutsForSelectedDate();
  }

  Future<void> loadWorkoutsForSelectedDate() async {
    workouts = await db.getWorkoutsByDate(selectedDate);
    setsCache.clear();
    for (var w in workouts) {
      setsCache[w.id] = await db.getSetsByWorkout(w.id);
    }
    notifyListeners();
  }

  Future<void> addWorkout(Workout w) async {
    await db.insertWorkout(w);
    await loadWorkoutsForSelectedDate();
  }

  Future<void> toggleSetDone(int workoutId, int setId, bool done) async {
    var list = setsCache[workoutId];
    if (list == null) {
      list = await db.getSetsByWorkout(workoutId);
      setsCache[workoutId] = list;
    }
    int idx = list.indexWhere((s) => s.id == setId);
    if (idx >= 0) {
      list[idx].done = done;
      await db.updateSet(list[idx]);
      notifyListeners();
    } else {
      await loadWorkoutsForSelectedDate();
    }
  }

  double progressForWorkout(int workoutId) {
    final list = setsCache[workoutId];
    if (list == null || list.isEmpty) return 0.0;
    final done = list.where((s) => s.done).length;
    return done / list.length;
  }

  int totalSetsDoneForDate() {
    int done = 0;
    int total = 0;
    for (var entry in setsCache.entries) {
      total += entry.value.length;
      done += entry.value.where((s) => s.done).length;
    }
    if (total == 0) return 0;
    return ((done / total) * 100).round();
  }
}

// -----------------------------
// Main App
// -----------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => WorkoutProvider(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: MainScreen(),
      ),
    ),
  );
}

// -----------------------------
// UI: MainScreen (Calendar + list)
// -----------------------------
class MainScreen extends StatefulWidget {
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  DateTime monthShown = DateTime.now();

  List<DateTime> _datesOfMonth(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final last = DateTime(month.year, month.month + 1, 0);
    List<DateTime> days = [];
    for (int i = 0; i < last.day; i++) {
      days.add(DateTime(month.year, month.month, i + 1));
    }
    return days;
  }

  void prevMonth() {
    setState(() {
      monthShown = DateTime(monthShown.year, monthShown.month - 1, 1);
    });
  }

  void nextMonth() {
    setState(() {
      monthShown = DateTime(monthShown.year, monthShown.month + 1, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context);
    final days = _datesOfMonth(monthShown);
    final percent = provider.totalSetsDoneForDate();

    return Scaffold(
      appBar: AppBar(
        title: Text('Main화면'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Month header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: Icon(Icons.chevron_left), onPressed: prevMonth),
              Text('${monthShown.month}월', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: Icon(Icons.chevron_right), onPressed: nextMonth),
            ],
          ),
          // Horizontal scrollable dates
          SizedBox(
            height: 90,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              itemBuilder: (context, idx) {
                final d = days[idx];
                bool isSelected = provider.selectedDate ==
                    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                return GestureDetector(
                  onTap: () {
                    provider.selectDate(d);
                  },
                  child: Container(
                    width: 90,
                    margin: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.blue.shade100 : Colors.grey.shade100,
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('${d.day}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        SizedBox(height: 6),
                        Text('${d.month}/${d.year}', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // Progress summary for selected date
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: percent / 100,
                    minHeight: 12,
                  ),
                ),
                SizedBox(width: 12),
                Text('$percent%'),
              ],
            ),
          ),
          // Workout list
          Expanded(
            child: provider.workouts.isEmpty
                ? Center(child: Text('해당 날짜의 운동이 없습니다.'))
                : ListView.builder(
              itemCount: provider.workouts.length,
              itemBuilder: (context, idx) {
                final w = provider.workouts[idx];
                final progress = provider.progressForWorkout(w.id);
                return Card(
                  margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    title: Text(w.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${w.sets} sets × ${w.reps} reps'),
                        SizedBox(height: 6),
                        LinearProgressIndicator(value: progress),
                      ],
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.chevron_right),
                      onPressed: () {
                        Navigator.of(context).push(MaterialPageRoute(builder: (context) => WorkoutDetailScreen(workout: w)));
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          children: [
            IconButton(onPressed: () {}, icon: Icon(Icons.share)),
            IconButton(onPressed: () {}, icon: Icon(Icons.info)),
            Spacer(),
            IconButton(
                onPressed: () {
                  // main button placeholder
                },
                icon: Icon(Icons.home)),
            Spacer(),
            IconButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (context) => StatisticScreen()));
                },
                icon: Icon(Icons.bar_chart)),
            IconButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (context) => WriteScreen(initialDate: provider.selectedDate)));
                },
                icon: Icon(Icons.edit)),
          ],
        ),
      ),
    );
  }
}

// -----------------------------
// Write Screen
// -----------------------------
class WriteScreen extends StatefulWidget {
  final String initialDate;
  WriteScreen({required this.initialDate});

  @override
  State<WriteScreen> createState() => _WriteScreenState();
}

class _WriteScreenState extends State<WriteScreen> {
  final _formKey = GlobalKey<FormState>();
  late DateTime _selectedDate;
  final _nameController = TextEditingController();
  final _repsController = TextEditingController(text: '10');
  final _setsController = TextEditingController(text: '3');
  final _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    var parts = widget.initialDate.split('-');
    _selectedDate = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _repsController.dispose();
    _setsController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context, listen: false);
    return Scaffold(
      appBar: AppBar(title: Text('Write화면')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${_selectedDate.year}년 ${_selectedDate.month}월 ${_selectedDate.day}일',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  TextButton(
                    child: Text('날짜 변경'),
                    onPressed: () async {
                      DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100));
                      if (picked != null) {
                        setState(() {
                          _selectedDate = picked;
                        });
                      }
                    },
                  )
                ],
              ),
              SizedBox(height: 12),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: InputDecoration(labelText: '운동명', border: OutlineInputBorder()),
                      validator: (v) => v == null || v.trim().isEmpty ? '운동명을 입력하세요' : null,
                    ),
                    SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _repsController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: 'reps', border: OutlineInputBorder()),
                            validator: (v) => (v == null || int.tryParse(v) == null) ? '숫자 입력' : null,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _setsController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: 'sets', border: OutlineInputBorder()),
                            validator: (v) => (v == null || int.tryParse(v) == null) ? '숫자 입력' : null,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    TextFormField(
                      controller: _commentController,
                      decoration: InputDecoration(labelText: 'Comment', border: OutlineInputBorder()),
                      maxLines: 3,
                    ),
                    SizedBox(height: 12),
                    ElevatedButton(
                      child: Text('+ 운동 추가하기'),
                      onPressed: () async {
                        if (_formKey.currentState!.validate()) {
                          final w = Workout(
                            date: '${_selectedDate.year.toString().padLeft(4, '0')}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}',
                            name: _nameController.text.trim(),
                            sets: int.parse(_setsController.text),
                            reps: int.parse(_repsController.text),
                            comment: _commentController.text.trim(),
                          );
                          await provider.addWorkout(w);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('운동이 추가되었습니다.')));
                          Navigator.of(context).pop();
                        }
                      },
                    )
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------
// Workout detail
// -----------------------------
class WorkoutDetailScreen extends StatefulWidget {
  final Workout workout;
  WorkoutDetailScreen({required this.workout});

  @override
  State<WorkoutDetailScreen> createState() => _WorkoutDetailScreenState();
}

class _WorkoutDetailScreenState extends State<WorkoutDetailScreen> {
  late WorkoutProvider provider;
  bool loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    provider = Provider.of<WorkoutProvider>(context, listen: false);
    if (!loaded) {
      _ensureSets();
    }
  }

  Future<void> _ensureSets() async {
    if (!provider.setsCache.containsKey(widget.workout.id)) {
      provider.setsCache[widget.workout.id] = await provider.db.getSetsByWorkout(widget.workout.id);
    }
    setState(() {
      loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sets = provider.setsCache[widget.workout.id] ?? [];
    return Scaffold(
      appBar: AppBar(title: Text(widget.workout.name)),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            if (widget.workout.comment.isNotEmpty) Text(widget.workout.comment),
            SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: sets.length,
                itemBuilder: (context, idx) {
                  final s = sets[idx];
                  return CheckboxListTile(
                    title: Text('Set ${s.setIndex + 1} — ${s.reps} reps'),
                    value: s.done,
                    onChanged: (v) async {
                      await provider.toggleSetDone(widget.workout.id, s.id, v ?? false);
                      setState(() {});
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: LinearProgressIndicator(value: provider.progressForWorkout(widget.workout.id)),
            )
          ],
        ),
      ),
    );
  }
}

// -----------------------------
// Statistic Screen
// -----------------------------
class StatisticScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context);
    final percent = provider.totalSetsDoneForDate();
    return Scaffold(
      appBar: AppBar(title: Text('Statistic')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('선택 날짜: ${provider.selectedDate}'),
            SizedBox(height: 12),
            Text('완료 비율: $percent%'),
            SizedBox(height: 12),
            ElevatedButton(
              child: Text('다시 불러오기'),
              onPressed: () async {
                await provider.loadWorkoutsForSelectedDate();
              },
            )
          ],
        ),
      ),
    );
  }
}