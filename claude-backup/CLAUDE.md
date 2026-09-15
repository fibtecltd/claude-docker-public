# Global Development Standards

## Diagram Generation

When generating PlantUML diagrams, always validate syntax before presenting. Common issues to check:
- Proper @startuml/@enduml tags
- Correct arrow syntax (-->)
- Quoted strings for labels with spaces
- Proper participant/class declarations

## Tool Usage Preferences

Do not use the TodoWrite tool. If you need to track tasks, describe them in conversational text instead.

## Python Coding Standards

### Variable Initialization and Assignment

Always write Python code that avoids "possibly unbound" and "might be referenced before assignment" static analysis warnings.

#### Core Rules

1. **Initialize variables before conditional use**
   - Always initialize with None, empty collections, or appropriate default values
   - Declare variables at function start when their scope spans multiple conditionals
   - Prefer explicit initialization over relying on exception handling

2. **Avoid "possibly unbound" warnings**
```python
   # BAD - variable might not be assigned
   if condition:
       result = calculate()
   return result  # Warning: might be unbound
   
   # GOOD - always initialized
   result = None
   if condition:
       result = calculate()
   return result
```

3. **Initialize loop aggregation variables**
```python
   # BAD - accumulator not initialized
   for item in items:
       total += item  # Warning: total might be unbound
   
   # GOOD - explicit initialization
   total = 0
   for item in items:
       total += item
```

4. **Handle all code paths in conditionals**
```python
   # BAD - not all paths assign
   if condition_a:
       value = compute_a()
   elif condition_b:
       value = compute_b()
   # What if neither condition is true?
   
   # GOOD - all paths covered
   if condition_a:
       value = compute_a()
   elif condition_b:
       value = compute_b()
   else:
       value = default_value
```

5. **Initialize before try/except blocks**
```python
   # BAD - might not be assigned if exception occurs early
   try:
       data = load_data()
       result = process(data)
   except Exception:
       pass
   return result  # Warning: might be unbound
   
   # GOOD - initialized before try
   result = None
   try:
       data = load_data()
       result = process(data)
   except Exception:
       pass
   return result
```

6. **Function return values**
   - Initialize return variables at function start
   - Ensure all code paths assign to return variables
   - Use explicit None returns when appropriate
```python
   # GOOD pattern
   def calculate(x: float) -> Optional[float]:
       result = None
       if x > 0:
           result = math.sqrt(x)
       elif x == 0:
           result = 0.0
       return result
```

#### Type Hints for Clarity

Use type hints to make initialization intent clear:
```python
from typing import Optional, List, Dict

# Clear intent: can be None
result: Optional[float] = None

# Clear intent: starts empty
items: List[str] = []
cache: Dict[str, Any] = {}
```

#### Special Considerations for Numerical/Numba Code

When working with Numba-optimized or complex numerical code where type inference is difficult:
- Prioritize runtime correctness over static analysis warnings
- Document why specific initialization patterns exist
- Use type hints where they improve clarity without breaking optimization
- Accept that some legitimate patterns may trigger warnings in complex cases

#### Enforcement

Apply these rules by default when generating or refactoring Python code. Proactively initialize variables to avoid warnings during code review and static analysis.
