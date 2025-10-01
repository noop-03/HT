import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:fl_chart/fl_chart.dart';
import 'package:table_calendar/table_calendar.dart';

// -----------------------------
// 데이터 모델
// -----------------------------
class WorkoutSet {
  int id;
  int workoutId;
  int setIndex;
  int reps;
  bool done;

  WorkoutSet({
    this.id = 0,
    required this.workoutId,
    required this.setIndex,
    required this.reps,
    this.done = false,
  });

  Map<String, dynamic> toMap({bool withId = false}) => {
        if (withId && id != 0) 'id': id,
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

  Map<String, dynamic> toMap({bool withId = false}) => {
        if (withId && id != 0) 'id': id,
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
// 데이터베이스 헬퍼
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
      int id = await txn.insert('workouts', w.toMap(withId: false));
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
    await database.update('sets', s.toMap(withId: true), where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> deleteWorkout(int id) async {
    final database = await db;
    await database.delete('sets', where: 'workoutId = ?', whereArgs: [id]);
    await database.delete('workouts', where: 'id = ?', whereArgs: [id]);
  }
}

// -----------------------------
// 상태관리 Provider
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

  Future<void> deleteWorkout(int workoutId) async {
    await db.deleteWorkout(workoutId);
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

  int totalSetsDoneForSelectedDate() {
    int done = 0;
    int total = 0;
    for (var w in workouts) {
      final sets = setsCache[w.id] ?? [];
      total += sets.length;
      done += sets.where((s) => s.done).length;
    }
    if (total == 0) return 0;
    return ((done / total) * 100).round();
  }

  Map<String, int> getWorkoutCountsByDate() {
    Map<String, int> counts = {};
    for (var w in workouts) {
      counts[w.date] = (counts[w.date] ?? 0) + 1;
    }
    return counts;
  }
}

// -----------------------------
// 앱 시작
// -----------------------------
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => WorkoutProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '운동 기록 앱',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [
        Locale('ko', 'KR'),
        Locale('en', 'US'),
      ],
    );
  }
}

// -----------------------------
// 홈 화면: 하단 탭 이동
// -----------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final _screens = const [
    MainScreen(),
    StatsScreen(),
    CalendarScreen(),
  ];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.edit), label: "기록"),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: "통계"),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_today), label: "캘린더"),
        ],
      ),
    );
  }
}

// -----------------------------
// 메인(기록)화면: 날짜별 리스트 및 입력 이동
// -----------------------------
class MainScreen extends StatelessWidget {
  const MainScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context);
    final workouts = provider.workouts;
    final percent = provider.totalSetsDoneForSelectedDate();

    return Scaffold(
      appBar: AppBar(title: const Text('운동 기록')),
      body: Column(
        children: [
          // 날짜 선택 바
          Padding(
            padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    final dt = DateTime.parse(provider.selectedDate);
                    final prev = dt.subtract(const Duration(days: 1));
                    provider.selectDate(prev);
                  },
                ),
                Text(
                  provider.selectedDate,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () {
                    final dt = DateTime.parse(provider.selectedDate);
                    final next = dt.add(const Duration(days: 1));
                    provider.selectDate(next);
                  },
                ),
              ],
            ),
          ),
          // 전체 완료율
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: percent / 100,
                    minHeight: 12,
                  ),
                ),
                const SizedBox(width: 12),
                Text('$percent%'),
              ],
            ),
          ),
          // 운동 리스트
          Expanded(
            child: workouts.isEmpty
                ? const Center(child: Text('해당 날짜의 운동이 없습니다.'))
                : ListView.builder(
                    itemCount: workouts.length,
                    itemBuilder: (context, idx) {
                      final w = workouts[idx];
                      final progress = provider.progressForWorkout(w.id);
                      return Card(
                        key: ValueKey(w.id),
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          title: Text(w.name),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${w.sets}세트 × ${w.reps}회'),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: progress),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                tooltip: '삭제',
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('운동 삭제'),
                                      content: const Text('정말로 이 운동을 삭제하시겠습니까?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(false),
                                          child: const Text('취소'),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(true),
                                          child: const Text('삭제', style: TextStyle(color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await provider.deleteWorkout(w.id);
                                  }
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () {
                                  Navigator.of(context).push(MaterialPageRoute(
                                      builder: (context) => WorkoutDetailScreen(workout: w)));
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => WriteScreen(initialDate: provider.selectedDate)));
        },
      ),
    );
  }
}

// -----------------------------
// 운동 추가 화면
// -----------------------------
class WriteScreen extends StatefulWidget {
  final String initialDate;
  const WriteScreen({super.key, required this.initialDate});

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
      appBar: AppBar(title: const Text('운동 추가')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${_selectedDate.year}년 ${_selectedDate.month}월 ${_selectedDate.day}일',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  TextButton(
                    child: const Text('날짜 변경'),
                    onPressed: () async {
                      DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                          locale: const Locale('ko', 'KR'),
                      );
                      if (picked != null) {
                        setState(() {
                          _selectedDate = picked;
                        });
                      }
                    },
                  )
                ],
              ),
              const SizedBox(height: 12),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(labelText: '운동명', border: OutlineInputBorder()),
                      validator: (v) => v == null || v.trim().isEmpty ? '운동명을 입력하세요' : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _repsController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: '횟수(회)', border: OutlineInputBorder()),
                            validator: (v) => (v == null || int.tryParse(v) == null) ? '숫자를 입력하세요' : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _setsController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: '세트(세트수)', border: OutlineInputBorder()),
                            validator: (v) => (v == null || int.tryParse(v) == null) ? '숫자를 입력하세요' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _commentController,
                      decoration: const InputDecoration(labelText: '메모', border: OutlineInputBorder()),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      child: const Text('+ 운동 추가하기'),
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
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('운동이 추가되었습니다.')));
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
// 운동 상세 화면
// -----------------------------
class WorkoutDetailScreen extends StatefulWidget {
  final Workout workout;
  const WorkoutDetailScreen({super.key, required this.workout});

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
      provider.setsCache[widget.workout.id] =
          await provider.db.getSetsByWorkout(widget.workout.id);
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
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: sets.length,
                itemBuilder: (context, idx) {
                  final s = sets[idx];
                  return CheckboxListTile(
                    title: Text('세트 ${s.setIndex + 1} — ${s.reps}회'),
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
              child: LinearProgressIndicator(
                  value: provider.progressForWorkout(widget.workout.id)),
            )
          ],
        ),
      ),
    );
  }
}

// -----------------------------
// 통계 화면: BarChart
// -----------------------------
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context);
    final Map<String, int> counts = {};
    for (var w in provider.workouts) {
      counts[w.date] = (counts[w.date] ?? 0) + 1;
    }
    final entries = counts.entries.toList();
    entries.sort((a, b) => a.key.compareTo(b.key));
    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < entries.length; i++) {
      barGroups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(toY: entries[i].value.toDouble(), width: 16),
        ],
      ));
    }

    return Scaffold(
      appBar: AppBar(title: const Text("운동 통계")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: barGroups.isEmpty
            ? const Center(child: Text("기록이 없습니다."))
            : BarChart(
                BarChartData(
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          int idx = value.toInt();
                          if (idx < 0 || idx >= entries.length) return Container();
                          final date = entries[idx].key;
                          return Text(date.substring(5), style: const TextStyle(fontSize: 10));
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: barGroups,
                ),
              ),
      ),
    );
  }
}

// -----------------------------
// 캘린더 화면: 날짜별 운동 상세 리스트
// -----------------------------
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WorkoutProvider>(context);

    Map<DateTime, List<Workout>> workoutEvents = {};
    for (var w in provider.workouts) {
      final parts = w.date.split('-');
      final day = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      workoutEvents[day] = [...(workoutEvents[day] ?? []), w];
    }

    List<Workout> getWorkoutsForDay(DateTime day) {
      return workoutEvents[DateTime(day.year, day.month, day.day)] ?? [];
    }

    return Scaffold(
      appBar: AppBar(title: const Text("운동 캘린더")),
      body: Column(
        children: [
          TableCalendar(
            focusedDay: _focusedDay,
            firstDay: DateTime(2020),
            lastDay: DateTime(2100),
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            eventLoader: getWorkoutsForDay,
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
                provider.selectDate(selectedDay);
              });
            },
            locale: 'ko_KR',
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              children: getWorkoutsForDay(_selectedDay ?? DateTime.now()).isEmpty
                  ? [const ListTile(title: Text('해당 날짜의 운동이 없습니다.'))]
                  : getWorkoutsForDay(_selectedDay ?? DateTime.now())
                      .map((w) => ListTile(
                            key: ValueKey(w.id),
                            leading: const Icon(Icons.check_circle),
                            title: Text(w.name),
                            subtitle: Text('${w.sets}세트 × ${w.reps}회'),
                            onTap: () {
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (context) => WorkoutDetailScreen(workout: w)));
                            },
                          ))
                      .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
